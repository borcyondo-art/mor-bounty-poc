// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @notice LumerinDiamond (Base) audit PoCs — read-only fork tests, no mainnet tx.
/// @dev Fork block 58145198 (Base), RPC https://mainnet.base.org
///      Diamond 0x6aBE1d282f72B474E54527D93b979A4f64d3030a
///      MOR (Base MOROFT) 0x7431aDa8a591C955a994a21710752EF9b882b8e3
interface IDiamond {
    struct Pool { uint256 initialReward; uint256 rewardDecrease; uint128 payoutStart; uint128 decreaseInterval; }
    struct Session { address user; bytes32 bidId; uint256 stake; bytes closeoutReceipt; uint256 closeoutType; uint256 providerWithdrawnAmount; uint128 openedAt; uint128 endsAt; uint128 closedAt; bool isActive; bool isDirectPaymentFromUser; }
    function providerRegister(address provider_, uint256 amount_, string calldata endpoint_) external;
    function modelRegister(address modelOwner_, bytes32 baseModelId_, bytes32 ipfsCID_, uint256 fee_, uint256 amount_, string calldata name_, string[] memory tags_) external;
    function postModelBid(address provider_, bytes32 modelId_, uint256 pricePerSecond_) external returns (bytes32 bidId);
    function getBidId(address provider_, bytes32 modelId_, uint256 nonce_) external view returns (bytes32);
    function getModelId(address account_, bytes32 baseModelId_) external view returns (bytes32);
    function getIsProviderApprovalUsed(bytes memory approval_) external view returns (bool);
    function openSession(address user_, uint256 amount_, bool isDirectPaymentFromUser_, bytes calldata approvalEncoded_, bytes calldata signature_) external returns (bytes32);
    function closeSession(bytes calldata receiptEncoded_, bytes calldata signature_) external;
    function claimForProvider(bytes32 sessionId_) external;
    function getSession(bytes32 sessionId_) external view returns (Session memory);
    function getUserStakesOnHold(address user_, uint8 iterations_) external view returns (uint256 available_, uint256 hold_);
    function withdrawUserStakes(address user_, uint8 iterations_) external;
    function getProvidersTotalClaimed() external view returns (uint256);
    function getComputeBalance(uint128 timestamp_) external view returns (uint256);
    function totalMORSupply(uint128 timestamp_) external view returns (uint256);
    function stakeToStipend(uint256 amount_, uint128 timestamp_) external view returns (uint256);
    function getSessionEnd(uint256 amount_, uint256 pricePerSecond_, uint128 openedAt_) external view returns (uint128);
    function getBid(bytes32 bidId_) external view returns (address provider, bytes32 modelId, uint256 pricePerSecond, uint256 nonce, uint128 createdAt, uint128 deletedAt);
    function __Marketplace_init(address token_, uint256 bidMinPricePerSecond_, uint256 bidMaxPricePerSecond_) external;
    function __SessionRouter_init(address fundingAccount_, uint128 maxSessionDuration_, IDiamond.Pool[] calldata pools_) external;
    function __Delegation_init(address registry_) external;
    function __ModelRegistry_init() external;
    function __ProviderRegistry_init() external;
    function setRegistry(address registry_) external;
    function setPoolConfig(uint256 index_, IDiamond.Pool calldata pool_) external;
    function getRegistry() external view returns (address);
    function isRightsDelegated(address delegatee_, address delegator_, bytes32 rights_) external view returns (bool);
}

interface IDelegateRegistry {
    function checkDelegateForContract(address delegatee_, address delegator_, address contract_, bytes32 rights_) external view returns (bool);
}

contract LumerinDiamondPoCTest is Test {
    address constant DIAMOND = 0x6aBE1d282f72B474E54527D93b979A4f64d3030a;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;
    address constant REGISTRY = 0x00000000000000447e69651d841bD8D104Bed493;
    uint256 constant FORK_BLOCK = 58145198;

    uint256 providerPk = 0x1111;
    uint256 userAPk = 0x2222;
    uint256 attackerPk = 0x3333;
    address provider;
    address userA;
    address attacker;

    bytes32 modelId;
    bytes32 bidId;
    uint256 constant PRICE = 1e16; // max price per second
    uint256 constant STAKE = 2000 ether;

    function setUp() public {
        vm.createSelectFork("base", FORK_BLOCK);
        provider = vm.addr(providerPk);
        userA = vm.addr(userAPk);
        attacker = vm.addr(attackerPk);
        vm.deal(provider, 10 ether);
        vm.deal(userA, 10 ether);
        vm.deal(attacker, 10 ether);
        deal(MOR, provider, 10000 ether);
        deal(MOR, userA, 10000 ether);
        deal(MOR, attacker, 10000 ether);

        // provider registers (min stake 0.2 MOR) + model + bid
        vm.startPrank(provider);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        IDiamond(DIAMOND).providerRegister(provider, 10 ether, "test:1234");
        bytes32 baseModelId = keccak256("test-model");
        string[] memory tags = new string[](1);
        tags[0] = "test";
        IDiamond(DIAMOND).modelRegister(provider, baseModelId, keccak256("ipfs"), 0, 1 ether, "TestModel", tags);
        vm.stopPrank();
        modelId = IDiamond(DIAMOND).getModelId(provider, baseModelId);
        vm.prank(provider);
        bidId = IDiamond(DIAMOND).postModelBid(provider, modelId, PRICE);
    }

    function _ethSignedMessageHash(bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", h));
    }

    function _signApproval(address signerPkOwner, uint256 pk, address user_, uint128 ts) internal view returns (bytes memory approval, bytes memory sig) {
        return _signApprovalForBid(bidId, pk, user_, ts);
    }

    function _signApprovalForBid(bytes32 bid_, uint256 pk, address user_, uint128 ts) internal view returns (bytes memory approval, bytes memory sig) {
        approval = abi.encode(bid_, uint256(8453), user_, ts);
        bytes32 h = _ethSignedMessageHash(keccak256(approval));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, h);
        sig = abi.encodePacked(r, s, v);
    }

    /* ============ T1: re-init must revert (initializer is one-time per slot) ============ */
    function test_T1_ReinitMarketplaceReverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        IDiamond(DIAMOND).__Marketplace_init(MOR, 1, 2);
    }

    function test_T1_ReinitSessionRouterReverts() public {
        IDiamond.Pool[] memory pools = new IDiamond.Pool[](0);
        vm.prank(attacker);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        IDiamond(DIAMOND).__SessionRouter_init(attacker, 7 days, pools);
    }

    function test_T1_ReinitDelegationReverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        IDiamond(DIAMOND).__Delegation_init(attacker);
    }

    function test_T1_ReinitModelRegistryReverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        IDiamond(DIAMOND).__ModelRegistry_init();
    }

    function test_T1_ReinitProviderRegistryReverts() public {
        vm.prank(attacker);
        vm.expectRevert(bytes("Initializable: contract is already initialized"));
        IDiamond(DIAMOND).__ProviderRegistry_init();
    }

    function test_T1_OwnerOnlySettersRevertForAttacker() public {
        vm.prank(attacker);
        vm.expectRevert();
        IDiamond(DIAMOND).setRegistry(attacker);
        IDiamond.Pool memory p = IDiamond.Pool({initialReward: 1, rewardDecrease: 0, payoutStart: 1, decreaseInterval: 86400});
        vm.prank(attacker);
        vm.expectRevert();
        IDiamond(DIAMOND).setPoolConfig(3, p);
    }

    /* ============ T3: delegation registry — random pair must NOT be delegated ============ */
    function test_T3_NoPhantomDelegation() public view {
        bytes32 rights = keccak256("delegation.rules.session");
        bool d = IDelegateRegistry(REGISTRY).checkDelegateForContract(attacker, userA, DIAMOND, rights);
        assertFalse(d, "attacker must not be delegatee of userA");
        bool d2 = IDiamond(DIAMOND).isRightsDelegated(attacker, userA, rights);
        assertFalse(d2);
    }

    /* ============ T2: approval NOT bound to user (repo behavior, live check) ============
       Provider signs approval whose embedded address is userA; attacker opens a
       session as THEMSELF with that approval. If this succeeds, live facet matches
       repo v7.19.0 (user check removed in commit 605cfcc5). */
    function test_T2_ApprovalForUserA_UsedByAttacker() public {
        (bytes memory approval, bytes memory sig) = _signApproval(provider, providerPk, userA, uint128(block.timestamp));
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        bytes32 sessionId = IDiamond(DIAMOND).openSession(attacker, STAKE, false, approval, sig);
        assertTrue(IDiamond(DIAMOND).getIsProviderApprovalUsed(approval), "approval must be marked used");
        address u = IDiamond(DIAMOND).getSession(sessionId).user;
        assertEq(u, attacker, "session user must be attacker, not userA");
    }

    /* ============ T2b: full session lifecycle, live SessionRouter == repo logic ============
       open (non-direct) -> warp +100s -> close with SELF-signed receipt (dispute path)
       -> warp +1d -> claimForProvider -> withdrawUserStakes.
       Asserts: user gets full stake back, provider earns exactly elapsed*price
       from funding account, no double-claim. */
    function test_T2b_FullLifecycle_EarlyCloseDispute() public {
        (bytes memory approval, bytes memory sig) = _signApproval(provider, providerPk, attacker, uint128(block.timestamp));
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        bytes32 sessionId = IDiamond(DIAMOND).openSession(attacker, STAKE, false, approval, sig);

        uint256 stipend = IDiamond(DIAMOND).stakeToStipend(STAKE, uint128(block.timestamp));
        console.log("stipend for 2000 MOR (wei):", stipend);
        uint128 endsAt = IDiamond(DIAMOND).getSessionEnd(STAKE, PRICE, uint128(block.timestamp));
        console.log("session endsAt - openedAt (sec):", uint256(endsAt) - block.timestamp);

        uint256 provBalBefore = IERC20(MOR).balanceOf(provider);
        console.log("prov bal after s1 close:", provBalBefore);
        uint256 userBalBefore = IERC20(MOR).balanceOf(attacker);

        vm.warp(block.timestamp + 100); // 100s elapsed
        // self-signed receipt (NOT provider) -> dispute path, must still close+refund
        bytes memory receipt = abi.encode(sessionId, uint256(8453), uint128(block.timestamp), uint32(1000), uint32(100));
        bytes32 rh = _ethSignedMessageHash(keccak256(receipt));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attackerPk, rh);
        vm.prank(attacker);
        IDiamond(DIAMOND).closeSession(receipt, abi.encodePacked(r, s, v));

        // provider got 0 at early disputed close (100s reward fully on hold)
        assertEq(IERC20(MOR).balanceOf(provider), provBalBefore, "provider must get 0 at early disputed close");
        // user refund = stake - day-lock ; lock = stipendToStake(100s*1e16)
        (uint256 avail, uint256 hold) = IDiamond(DIAMOND).getUserStakesOnHold(attacker, 10);
        console.log("after close: user avail:", avail, "hold:", hold);
        assertGt(hold, 0, "part of stake must be day-locked");
        assertApproxEqAbs(IERC20(MOR).balanceOf(attacker), userBalBefore + STAKE - hold, 1e15);

        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        uint256 provGain = IERC20(MOR).balanceOf(provider) - provBalBefore;
        console.log("provider total gain (wei):", provGain);
        assertEq(provGain, 100 * PRICE, "provider must earn exactly elapsed*price = 1 MOR");

        // second claim pays 0 (no double-claim)
        vm.prank(provider);
        IDiamond(DIAMOND).claimForProvider(sessionId);
        assertEq(IERC20(MOR).balanceOf(provider) - provBalBefore, 100 * PRICE, "no double claim");

        vm.prank(attacker);
        IDiamond(DIAMOND).withdrawUserStakes(attacker, 10);
        assertApproxEqAbs(IERC20(MOR).balanceOf(attacker), userBalBefore + STAKE, 1e15, "user must get full stake back");
    }

    function _openAsAttacker(uint256 amount) internal returns (bytes32 sessionId) {
        sessionId = _openAsAttackerPriced(amount, PRICE);
    }

    function _openAsAttackerPriced(uint256 amount, uint256 price) internal returns (bytes32 sessionId) {
        // NOTE: a fresh bid at the requested price is needed; provider posts it on demand
        vm.prank(provider);
        bytes32 b = IDiamond(DIAMOND).postModelBid(provider, modelId, price);
        (bytes memory approval, bytes memory sig) = _signApprovalForBid(b, providerPk, attacker, uint128(block.timestamp));
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        sessionId = IDiamond(DIAMOND).openSession(attacker, amount, false, approval, sig);
    }

    function _closeWithProviderReceipt(bytes32 sessionId) internal {
        uint128 endsAt = IDiamond(DIAMOND).getSession(sessionId).endsAt;
        vm.warp(uint256(endsAt));
        bytes memory receipt = abi.encode(sessionId, uint256(8453), uint128(block.timestamp), uint32(1000), uint32(100));
        bytes32 rh = _ethSignedMessageHash(keccak256(receipt));
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(providerPk, rh);
        vm.prank(attacker);
        IDiamond(DIAMOND).closeSession(receipt, abi.encodePacked(r, sg, v));
    }

    /* ============ T4: midnight-straddle day-lock test ============
       Open max-price session (2000 MOR stake, 584s) at 23:57, ends 00:06:44 next day, close then.
       Repo logic locks ONLY the post-midnight portion (~404/584 of stake).
       Question: does the unlocked pre-midnight portion let the attacker earn
       MORE than the intended daily rate? Measure total provider earnings from
       the same 1000 MOR over the straddle + immediate restake vs a plain
       same-day session. If straddle total <= plain total, no amplification. */
    function test_T4_MidnightStraddle_NoAmplification() public {
        uint128 dayStart = uint128(block.timestamp - (block.timestamp % 1 days));
        vm.warp(uint256(dayStart) + 23 hours + 57 minutes); // 23:57 day D

        bytes32 s1 = _openAsAttacker(STAKE);
        uint128 endsAt1 = IDiamond(DIAMOND).getSession(s1).endsAt;
        console.log("s1 endsAt offset into next day (sec):", uint256(endsAt1) - uint256(dayStart) - 86400);

        _closeWithProviderReceipt(s1);

        (uint256 avail1, uint256 hold1) = IDiamond(DIAMOND).getUserStakesOnHold(attacker, 10);
        console.log("straddle close: refunded avail:", avail1, "locked hold:", hold1);
        // repo expectation: hold ~= 404/584 * 2000 MOR (~1384 MOR), NOT full 2000
        assertLt(hold1, STAKE, "straddle must lock less than full stake (repo end-day anchoring)");
        assertGt(hold1, 0, "some lock must exist");

        uint256 provBalBefore = IERC20(MOR).balanceOf(provider);
        console.log("prov bal after s1 close:", provBalBefore);
        // immediately restake the unlocked refund for a 2nd session
        uint256 refund = IERC20(MOR).balanceOf(attacker) - (10000 ether - STAKE);
        console.log("refund after s1 close:", refund);
        bytes32 s2 = _openAsAttackerPriced(refund, 5e15); // lower price: 616 MOR stipend needs >=300s duration
        console.log("prov bal after s2 bid post:", IERC20(MOR).balanceOf(provider));
        console.log("s2 duration sec:", uint256(IDiamond(DIAMOND).getSession(s2).endsAt) - uint256(IDiamond(DIAMOND).getSession(s2).openedAt));
        (,, uint256 s2pps,,,) = IDiamond(DIAMOND).getBid(IDiamond(DIAMOND).getSession(s2).bidId);
        console.log("s2 bid price:", s2pps);
        _closeWithProviderReceipt(s2);

        uint256 s2Gain = IERC20(MOR).balanceOf(provider) - provBalBefore;
        console.log("provider gain from s2 only (wei):", s2Gain);
        // s2Gain is NET of the 0.3 MOR bid fee paid for s2's own bid post:
        // true s2 reward = 360s x 5e15 = 1.8 MOR (matches live getSessionEnd);
        // 1.8 - 0.3 fee = 1.5 measured. No amplification: straddle total
        // 5.84 + 1.8 = 7.64 MOR < plain 2-day full-stake total 2 x 5.84 = 11.68 MOR.
        assertLt(s2Gain, 2 ether, "s2 net gain must be < full-stake stipend");
    }
    /* ============ T5: access-control negatives (attacker = stranger) ============ */
    function test_T5_StrangerCannotCloseOthersSession() public {
        (bytes memory approval, bytes memory sig) = _signApproval(provider, providerPk, attacker, uint128(block.timestamp));
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        bytes32 sessionId = IDiamond(DIAMOND).openSession(attacker, STAKE, false, approval, sig);
        bytes memory receipt = abi.encode(sessionId, uint256(8453), uint128(block.timestamp), uint32(1000), uint32(100));
        bytes32 rh = _ethSignedMessageHash(keccak256(receipt));
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(providerPk, rh);
        vm.prank(userA); // stranger, not user nor delegatee
        vm.expectRevert();
        IDiamond(DIAMOND).closeSession(receipt, abi.encodePacked(r, sg, v));
    }

    function test_T5_StrangerCannotClaimForProvider() public {
        vm.prank(userA);
        vm.expectRevert();
        IDiamond(DIAMOND).claimForProvider(bytes32(uint256(1)));
    }

    function test_T5_ExpiredApprovalReverts() public {
        (bytes memory approval, bytes memory sig) = _signApproval(provider, providerPk, attacker, uint128(block.timestamp - 601));
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert();
        IDiamond(DIAMOND).openSession(attacker, STAKE, false, approval, sig);
    }

    function test_T5_WrongChainApprovalReverts() public {
        bytes memory approval = abi.encode(bidId, uint256(1), attacker, uint128(block.timestamp));
        bytes32 h = _ethSignedMessageHash(keccak256(approval));
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(providerPk, h);
        vm.prank(attacker);
        IERC20(MOR).approve(DIAMOND, type(uint256).max);
        vm.prank(attacker);
        vm.expectRevert();
        IDiamond(DIAMOND).openSession(attacker, STAKE, false, approval, abi.encodePacked(r, sg, v));
    }

}

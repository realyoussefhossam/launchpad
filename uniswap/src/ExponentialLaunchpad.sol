pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {LiquidityAmounts} from "v4-periphery/libraries/LiquidityAmounts.sol";
import {UniswapV4ERC20} from "./UniswapV4ERC20.sol";
import {
    IUnlockCallback
} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {
    TransientStateLibrary
} from "v4-core/src/libraries/TransientStateLibrary.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";

error SALE_IS_OVER();
error INITIAL_LIQUIDITY_NOT_PROVIDED();
error PURCHASE_AMOUNT_TOO_BIG();
error SENDER_MUST_BE_HOOK();
error POOL_NOT_INITIALIZED();
error TOO_MUCH_SLIPPAGE();
error SELL_EXCEEDS_MINTED();
error NOT_ELIGIBLE_YET();
error NO_REWARDS_AVAILABLE();
error POOL_NOT_MIGRATED();
error NO_FEES_TO_COLLECT();
error UNAUTHORIZED();

contract ExponentialLaunchpad is BaseHook {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for uint128;
    using TickMath for int24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Bonding curve tick range: token_address < usdc_address
    int24 internal constant MINIMUM_TICK = -345405;
    int24 internal constant MAXIMUM_TICK = -276324;

    // Bonding curve tick range: usdc_address < token_address
    int24 internal constant INVERT_MAXIMUM_TICK = 345405;
    int24 internal constant INVERT_MINIMUM_TICK = 276324;

    // --- KRYX Tax Constants (Phase 1) ---
    uint256 public constant BUY_TAX_BPS = 100; // 1%
    uint256 public constant SELL_TAX_BPS = 100; // 1%
    uint256 public constant COMMUNITY_BPS = 3000; // 30% of tax
    uint256 public constant CREATOR_BPS = 3500; // 35% of tax
    uint256 public constant PLATFORM_BPS = 3500; // 35% of tax
    uint256 public constant BPS_DENOMINATOR = 10000;

    // DPS precision multiplier
    uint256 internal constant DPS_PRECISION = 1e18;

    // Eligibility delay for DPS rewards
    uint256 public constant ELIGIBILITY_DELAY = 24 hours;

    // --- Per-Pool State ---
    mapping(PoolId => uint256) public tokenToMintSupply;
    mapping(PoolId => uint256) public mintedTokens;
    mapping(PoolId => address) public poolLpToken;
    mapping(PoolId => uint256) public poolToLPStartTime;
    mapping(PoolId => bool) public buyDirection;
    mapping(PoolId => bool) public migrated;

    // KRYX wallet config per pool
    mapping(PoolId => address) public creatorWallet;
    mapping(PoolId => address) public platformTreasury;

    // Tax revenue tracking (claimable balances in base asset)
    mapping(PoolId => uint256) public creatorAccrued;
    mapping(PoolId => uint256) public platformAccrued;

    // Total base asset raised per pool (net of taxes, used for migration)
    mapping(PoolId => uint256) public totalBaseRaised;

    // --- DPS Reward State ---
    mapping(PoolId => uint256) public dividendPerShare;
    mapping(PoolId => uint256) public totalEligibleTokens;

    struct UserInfo {
        uint256 balance; // total tokens held (bought via bonding curve)
        uint256 eligibleBalance; // tokens eligible for DPS rewards (after 24h)
        uint256 mask; // DPS mask for reward calculation
        uint256 lastPurchaseTimestamp; // timestamp of last purchase
        uint256 pendingEligible; // tokens waiting to become eligible
        uint256 claimableRewards; // accumulated rewards ready to claim
    }

    // poolId => user => UserInfo
    mapping(PoolId => mapping(address => UserInfo)) public userInfo;

    // --- Post-Migration Fee Splitter Config ---
    struct FeeConfig {
        uint256 protocolFeeBps; // e.g. 10 = 0.1%
        uint256 creatorFeeBps; // e.g. 20 = 0.2%
        uint256 lpRewardBps; // e.g. 15 = 0.15%
    }

    mapping(PoolId => FeeConfig) public feeConfig;

    // Base asset (TOKEN_ADDRESS is the payment token, e.g. USDC)
    address public immutable TOKEN_ADDRESS;

    constructor(
        IPoolManager _poolManager,
        address _tokenAddress
    ) BaseHook(_poolManager) {
        TOKEN_ADDRESS = _tokenAddress;
    }

    struct CallbackData {
        address sender;
        PoolKey key;
        IPoolManager.ModifyLiquidityParams params;
    }

    struct AddLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address to;
        uint256 deadline;
    }

    struct RemoveLiquidityParams {
        Currency currency0;
        Currency currency1;
        uint24 fee;
        uint256 liquidity;
        uint256 deadline;
    }

    modifier onlyPoolManager() {
        require(msg.sender == address(manager));
        _;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true,
                afterInitialize: false,
                beforeAddLiquidity: false,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    ///////////
    // Hooks //
    ///////////

    function beforeInitialize(
        address _initializer,
        PoolKey calldata key,
        uint160,
        bytes calldata data
    ) external override returns (bytes4) {
        PoolId poolId = key.toId();
        (
            uint256 maxTokenSupply,
            address _creatorWallet,
            address _platformTreasury,
            uint256 _protocolFeeBps,
            uint256 _creatorFeeBps,
            uint256 _lpRewardBps
        ) = abi.decode(
                data,
                (uint256, address, address, uint256, uint256, uint256)
            );
        buyDirection[poolId] = Currency.unwrap(key.currency0) == TOKEN_ADDRESS;

        // Send tokens to the pool manager (hook holds them as claims)
        if (buyDirection[poolId]) {
            key.currency1.settle(manager, _initializer, maxTokenSupply, false);
            key.currency1.take(manager, address(this), maxTokenSupply, true);
        } else {
            key.currency0.settle(manager, _initializer, maxTokenSupply, false);
            key.currency0.take(manager, address(this), maxTokenSupply, true);
        }

        tokenToMintSupply[poolId] = maxTokenSupply;
        mintedTokens[poolId] = 0;

        // Store KRYX config
        creatorWallet[poolId] = _creatorWallet;
        platformTreasury[poolId] = _platformTreasury;

        // Post-migration fee config
        feeConfig[poolId] = FeeConfig({
            protocolFeeBps: _protocolFeeBps,
            creatorFeeBps: _creatorFeeBps,
            lpRewardBps: _lpRewardBps
        });

        // Deploy ERC20 LP token
        address poolToken = address(new UniswapV4ERC20("MEME", "MEME"));
        poolLpToken[poolId] = poolToken;

        return this.beforeInitialize.selector;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata hookData
    )
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        bool exactInput = params.amountSpecified < 0;
        (Currency specified, Currency unspecified) = getCurrencies(
            params,
            key,
            exactInput
        );

        uint256 specifiedAmount = getSpecifiedAmount(params, exactInput);

        PoolId id = key.toId();

        // During bonding curve phase, handle via custom curve with tax
        if (!migrated[id]) {
            if (exactInput) {
                return
                    handleExactInput(
                        params,
                        key,
                        specified,
                        unspecified,
                        specifiedAmount,
                        hookData
                    );
            } else {
                return
                    handleExactOutput(
                        params,
                        key,
                        specified,
                        unspecified,
                        specifiedAmount,
                        hookData
                    );
            }
        }

        // Post-migration: no custom curve, no tax — let Uniswap V4 AMM handle it
        return (this.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
    }

    function handleExactInput(
        IPoolManager.SwapParams calldata params,
        PoolKey calldata key,
        Currency specified,
        Currency unspecified,
        uint256 specifiedAmount,
        bytes calldata hookData
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 unspecifiedAmount;
        BeforeSwapDelta returnDelta;

        PoolId id = key.toId();
        bool isBuy = Currency.unwrap(specified) == TOKEN_ADDRESS;

        // Apply tax
        uint256 taxBps = isBuy ? BUY_TAX_BPS : SELL_TAX_BPS;
        uint256 taxAmount = (specifiedAmount * taxBps) / BPS_DENOMINATOR;
        uint256 netAmount = specifiedAmount - taxAmount;

        // Distribute tax
        _distributeTax(id, taxAmount, isBuy);

        // Execute bonding curve swap with net amount
        (netAmount, unspecifiedAmount) = _bondingCurveExactInput(
            netAmount,
            specified,
            unspecified,
            params.zeroForOne,
            id,
            isBuy
        );

        // Track user balance for DPS
        if (hookData.length >= 20) {
            address swapper = abi.decode(hookData, (address));
            if (isBuy) {
                _onBuy(id, swapper, unspecifiedAmount);
            } else {
                _onSell(id, swapper, netAmount);
            }
        }

        // Take the full specifiedAmount from user (includes tax), settle unspecified
        uint256 totalTaken = netAmount + taxAmount;
        specified.take(manager, address(this), totalTaken, true);
        unspecified.settle(manager, address(this), unspecifiedAmount, true);
        returnDelta = toBeforeSwapDelta(
            totalTaken.toInt128(),
            -unspecifiedAmount.toInt128()
        );

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    function handleExactOutput(
        IPoolManager.SwapParams calldata params,
        PoolKey calldata key,
        Currency specified,
        Currency unspecified,
        uint256 specifiedAmount,
        bytes calldata hookData
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        uint256 unspecifiedAmount;
        BeforeSwapDelta returnDelta;

        PoolId id = key.toId();
        bool isBuy = Currency.unwrap(unspecified) == TOKEN_ADDRESS;

        // Get base cost from bonding curve
        (unspecifiedAmount, ) = _bondingCurveExactOutput(
            specifiedAmount,
            specified,
            unspecified,
            params.zeroForOne,
            id,
            isBuy
        );

        // Apply tax on the unspecified (input) side
        uint256 taxBps = isBuy ? BUY_TAX_BPS : SELL_TAX_BPS;
        uint256 taxAmount = (unspecifiedAmount * taxBps) / BPS_DENOMINATOR;

        // Distribute tax
        _distributeTax(id, taxAmount, isBuy);

        uint256 totalUnspecified = unspecifiedAmount + taxAmount;

        // Track user balance for DPS
        if (hookData.length >= 20) {
            address swapper = abi.decode(hookData, (address));
            if (isBuy) {
                _onBuy(id, swapper, specifiedAmount);
            } else {
                _onSell(id, swapper, specifiedAmount);
            }
        }

        unspecified.take(manager, address(this), totalUnspecified, true);
        specified.settle(manager, address(this), specifiedAmount, true);
        returnDelta = toBeforeSwapDelta(
            -specifiedAmount.toInt128(),
            totalUnspecified.toInt128()
        );

        return (this.beforeSwap.selector, returnDelta, 0);
    }

    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, int128) {
        _checkAndMigrate(key);
        return (this.afterSwap.selector, 0);
    }

    ////////////////////////
    // Tax Distribution   //
    ////////////////////////

    function _distributeTax(PoolId id, uint256 taxAmount, bool isBuy) internal {
        if (taxAmount == 0) return;

        uint256 communityShare = (taxAmount * COMMUNITY_BPS) / BPS_DENOMINATOR;
        uint256 creatorShare = (taxAmount * CREATOR_BPS) / BPS_DENOMINATOR;
        uint256 platformShare = taxAmount - communityShare - creatorShare;

        // Credit creator and platform (claimable)
        creatorAccrued[id] += creatorShare;
        platformAccrued[id] += platformShare;

        // Update DPS for community rewards
        if (totalEligibleTokens[id] > 0 && communityShare > 0) {
            dividendPerShare[id] +=
                (communityShare * DPS_PRECISION) /
                totalEligibleTokens[id];
        }

        // Track base raised (only on buys the base asset comes in; on sells it goes out)
        if (isBuy) {
            totalBaseRaised[id] += taxAmount; // tax is also part of what the user paid
        }
    }

    ////////////////////////
    // DPS Reward System  //
    ////////////////////////

    function _onBuy(PoolId id, address user, uint256 tokenAmount) internal {
        UserInfo storage info = userInfo[id][user];

        // Settle any pending rewards before balance change
        _settleRewards(id, user);

        // Make previously pending tokens eligible if 24h has passed
        _updateEligibility(id, user);

        info.balance += tokenAmount;
        info.pendingEligible += tokenAmount;
        info.lastPurchaseTimestamp = block.timestamp;

        // Track base raised (net amount after tax already added in _distributeTax)
    }

    function _onSell(PoolId id, address user, uint256 tokenAmount) internal {
        UserInfo storage info = userInfo[id][user];
        if (info.balance < tokenAmount) revert SELL_EXCEEDS_MINTED();

        // Settle any pending rewards before balance change
        _settleRewards(id, user);

        // Make previously pending tokens eligible if 24h has passed
        _updateEligibility(id, user);

        info.balance -= tokenAmount;

        // Reduce from eligible first, then pending
        if (info.eligibleBalance >= tokenAmount) {
            info.eligibleBalance -= tokenAmount;
            totalEligibleTokens[id] -= tokenAmount;
        } else {
            uint256 fromEligible = info.eligibleBalance;
            uint256 fromPending = tokenAmount - fromEligible;
            totalEligibleTokens[id] -= fromEligible;
            info.eligibleBalance = 0;
            info.pendingEligible -= fromPending;
        }

        // Update mask after balance change
        info.mask =
            (info.eligibleBalance * dividendPerShare[id]) /
            DPS_PRECISION;
    }

    function _updateEligibility(PoolId id, address user) internal {
        UserInfo storage info = userInfo[id][user];
        if (
            info.pendingEligible > 0 &&
            block.timestamp >= info.lastPurchaseTimestamp + ELIGIBILITY_DELAY
        ) {
            info.eligibleBalance += info.pendingEligible;
            totalEligibleTokens[id] += info.pendingEligible;
            info.pendingEligible = 0;
            // Set mask so user doesn't get retroactive rewards
            info.mask =
                (info.eligibleBalance * dividendPerShare[id]) /
                DPS_PRECISION;
        }
    }

    function _settleRewards(PoolId id, address user) internal {
        UserInfo storage info = userInfo[id][user];
        if (info.eligibleBalance > 0) {
            uint256 owed = (info.eligibleBalance * dividendPerShare[id]) /
                DPS_PRECISION -
                info.mask;
            if (owed > 0) {
                info.claimableRewards += owed;
                info.mask =
                    (info.eligibleBalance * dividendPerShare[id]) /
                    DPS_PRECISION;
            }
        }
    }

    function claimRewards(
        PoolKey calldata key
    ) external returns (uint256 payout) {
        PoolId id = key.toId();
        address user = msg.sender;
        UserInfo storage info = userInfo[id][user];

        // Update eligibility first
        _updateEligibility(id, user);

        // Settle any pending DPS rewards into claimableRewards
        _settleRewards(id, user);

        payout = info.claimableRewards;

        if (payout == 0) revert NO_REWARDS_AVAILABLE();

        info.claimableRewards = 0;

        // Transfer base asset reward to user
        Currency baseAsset = Currency.wrap(TOKEN_ADDRESS);
        baseAsset.transfer(user, payout);
    }

    function pendingRewards(
        PoolKey calldata key,
        address user
    ) external view returns (uint256) {
        PoolId id = key.toId();
        UserInfo storage info = userInfo[id][user];
        uint256 pending = info.claimableRewards;
        if (info.eligibleBalance > 0) {
            pending +=
                (info.eligibleBalance * dividendPerShare[id]) /
                DPS_PRECISION -
                info.mask;
        }
        return pending;
    }

    /////////////////////////////
    // Bonding Curve Functions //
    /////////////////////////////

    function _bondingCurveExactInput(
        uint256 netAmount,
        Currency specified,
        Currency unspecified,
        bool zeroForOne,
        PoolId id,
        bool isBuy
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        if (mintedTokens[id] >= tokenToMintSupply[id]) revert SALE_IS_OVER();

        if (isBuy) {
            // Base asset in, tokens out
            return _buyExactInput(netAmount, zeroForOne, id);
        } else {
            // Tokens in, base asset out
            return _sellExactInput(netAmount, zeroForOne, id);
        }
    }

    function _bondingCurveExactOutput(
        uint256 specifiedAmount,
        Currency specified,
        Currency unspecified,
        bool zeroForOne,
        PoolId id,
        bool isBuy
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        if (mintedTokens[id] >= tokenToMintSupply[id]) revert SALE_IS_OVER();

        if (isBuy) {
            // User wants exact tokens out, needs to pay base asset
            return _buyExactOutput(specifiedAmount, zeroForOne, id);
        } else {
            // User wants exact base asset out, needs to send tokens
            return _sellExactOutput(specifiedAmount, zeroForOne, id);
        }
    }

    function _buyExactInput(
        uint256 baseAmountIn,
        bool zeroForOne,
        PoolId id
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        if (zeroForOne) {
            int24 currTick = MINIMUM_TICK +
                int24(
                    ((MAXIMUM_TICK - MINIMUM_TICK) * int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currTick);
            uint256 inverseTokenPurchased = (uint256(sqrtPriceX96) ** 2) /
                uint256(baseAmountIn);
            amountOut = 2 ** 192 / inverseTokenPurchased;
            if (mintedTokens[id] + amountOut > tokenToMintSupply[id]) {
                amountOut = tokenToMintSupply[id] - mintedTokens[id];
                amountIn =
                    (uint256(sqrtPriceX96) ** 2) /
                    (2 ** 192 / amountOut);
                mintedTokens[id] = tokenToMintSupply[id];
            } else {
                amountIn = baseAmountIn;
                mintedTokens[id] += amountOut;
            }
        } else {
            int24 currTick = INVERT_MAXIMUM_TICK -
                int24(
                    ((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) *
                        int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint256 sqrtPriceX96 = uint256(
                TickMath.getSqrtPriceAtTick(currTick)
            );
            uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2 ** 100;
            amountOut = (priceX92 * baseAmountIn) / 2 ** 92;
            if (mintedTokens[id] + amountOut > tokenToMintSupply[id]) {
                amountOut = tokenToMintSupply[id] - mintedTokens[id];
                amountIn = (2 ** 92 * amountOut) / priceX92;
                mintedTokens[id] = tokenToMintSupply[id];
            } else {
                amountIn = baseAmountIn;
                mintedTokens[id] += amountOut;
            }
        }

        totalBaseRaised[id] += amountIn;
    }

    function _buyExactOutput(
        uint256 tokenAmountOut,
        bool zeroForOne,
        PoolId id
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        if (tokenAmountOut + mintedTokens[id] > tokenToMintSupply[id])
            revert PURCHASE_AMOUNT_TOO_BIG();

        if (zeroForOne) {
            int24 currTick = MINIMUM_TICK +
                int24(
                    ((MAXIMUM_TICK - MINIMUM_TICK) * int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currTick);
            uint256 inverseTokenPurchased = 2 ** 192 / tokenAmountOut;
            amountIn =
                (inverseTokenPurchased * tokenAmountOut) /
                (uint256(sqrtPriceX96) ** 2);
        } else {
            int24 currTick = INVERT_MAXIMUM_TICK -
                int24(
                    ((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) *
                        int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint256 sqrtPriceX96 = uint256(
                TickMath.getSqrtPriceAtTick(currTick)
            );
            uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2 ** 100;
            amountIn = (2 ** 92 * tokenAmountOut) / priceX92;
        }
        amountOut = tokenAmountOut;
        mintedTokens[id] += amountOut;
        totalBaseRaised[id] += amountIn;
    }

    function _sellExactInput(
        uint256 tokenAmountIn,
        bool zeroForOne,
        PoolId id
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        if (tokenAmountIn > mintedTokens[id]) revert SELL_EXCEEDS_MINTED();

        if (zeroForOne) {
            // zeroForOne means currency0 in — if buyDirection says currency0 is TOKEN_ADDRESS
            // then this is a sell (token in, base out)
            int24 currTick = MINIMUM_TICK +
                int24(
                    ((MAXIMUM_TICK - MINIMUM_TICK) * int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currTick);
            // Reverse the buy formula: base = token * sqrtPrice^2 / 2^192
            amountOut =
                (tokenAmountIn * uint256(sqrtPriceX96) ** 2) /
                (2 ** 192);
        } else {
            int24 currTick = INVERT_MAXIMUM_TICK -
                int24(
                    ((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) *
                        int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint256 sqrtPriceX96 = uint256(
                TickMath.getSqrtPriceAtTick(currTick)
            );
            uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2 ** 100;
            // Reverse: base = token * 2^92 / priceX92
            amountOut = (tokenAmountIn * 2 ** 92) / priceX92;
        }

        amountIn = tokenAmountIn;
        mintedTokens[id] -= tokenAmountIn;
        if (totalBaseRaised[id] >= amountOut) {
            totalBaseRaised[id] -= amountOut;
        } else {
            totalBaseRaised[id] = 0;
        }
    }

    function _sellExactOutput(
        uint256 baseAmountOut,
        bool zeroForOne,
        PoolId id
    ) internal returns (uint256 amountIn, uint256 amountOut) {
        if (zeroForOne) {
            int24 currTick = MINIMUM_TICK +
                int24(
                    ((MAXIMUM_TICK - MINIMUM_TICK) * int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(currTick);
            // token = base * 2^192 / sqrtPrice^2
            amountIn =
                (baseAmountOut * 2 ** 192) /
                (uint256(sqrtPriceX96) ** 2);
        } else {
            int24 currTick = INVERT_MAXIMUM_TICK -
                int24(
                    ((INVERT_MAXIMUM_TICK - INVERT_MINIMUM_TICK) *
                        int256(mintedTokens[id])) /
                        int256(tokenToMintSupply[id])
                );
            uint256 sqrtPriceX96 = uint256(
                TickMath.getSqrtPriceAtTick(currTick)
            );
            uint256 priceX92 = (uint256(sqrtPriceX96) ** 2) / 2 ** 100;
            amountIn = (baseAmountOut * priceX92) / 2 ** 92;
        }

        if (amountIn > mintedTokens[id]) revert SELL_EXCEEDS_MINTED();

        amountOut = baseAmountOut;
        mintedTokens[id] -= amountIn;
        if (totalBaseRaised[id] >= amountOut) {
            totalBaseRaised[id] -= amountOut;
        } else {
            totalBaseRaised[id] = 0;
        }
    }

    ////////////////////////////
    // Migration (Graduation) //
    ////////////////////////////

    function _checkAndMigrate(PoolKey calldata key) internal {
        PoolId id = key.toId();

        if (migrated[id]) return;
        if (mintedTokens[id] < tokenToMintSupply[id]) return;

        // All tokens sold — trigger migration
        migrated[id] = true;

        // Deploy 100% of raised base asset + remaining tokens as LP
        uint256 baseAmount = totalBaseRaised[id];
        uint256 tokenAmount = tokenToMintSupply[id];

        if (baseAmount == 0) return;

        // Determine which currency is base vs token
        Currency baseCurrency = Currency.wrap(TOKEN_ADDRESS);
        Currency tokenCurrency = buyDirection[id]
            ? key.currency0
            : key.currency1;

        int256 delta0;
        int256 delta1;
        {
            int deltaBefore0 = manager.currencyDelta(
                address(this),
                key.currency0
            );
            int deltaBefore1 = manager.currencyDelta(
                address(this),
                key.currency1
            );

            // Calculate liquidity from available amounts
            (uint160 sqrtPriceX96, , , ) = manager.getSlot0(id);
            uint256 amount0ForLP;
            uint256 amount1ForLP;
            if (buyDirection[id]) {
                // currency0 = TOKEN_ADDRESS (base), currency1 = meme token
                amount0ForLP = baseAmount;
                amount1ForLP = tokenAmount;
            } else {
                // currency0 = meme token, currency1 = TOKEN_ADDRESS (base)
                amount0ForLP = tokenAmount;
                amount1ForLP = baseAmount;
            }

            uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
                sqrtPriceX96,
                TickMath.getSqrtPriceAtTick(
                    TickMath.minUsableTick(key.tickSpacing)
                ),
                TickMath.getSqrtPriceAtTick(
                    TickMath.maxUsableTick(key.tickSpacing)
                ),
                amount0ForLP,
                amount1ForLP
            );

            if (liquidity == 0) return;

            (BalanceDelta callerDelta, ) = manager.modifyLiquidity(
                key,
                IPoolManager.ModifyLiquidityParams({
                    tickLower: TickMath.minUsableTick(key.tickSpacing),
                    tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                    liquidityDelta: int256(uint256(liquidity)),
                    salt: 0
                }),
                ""
            );

            int deltaAfter0 = manager.currencyDelta(
                address(this),
                key.currency0
            );
            int deltaAfter1 = manager.currencyDelta(
                address(this),
                key.currency1
            );
            delta0 = deltaAfter0 - deltaBefore0;
            delta1 = deltaAfter1 - deltaBefore1;

            // Mint LP tokens to this contract (locked)
            UniswapV4ERC20(poolLpToken[id]).mint(
                address(this),
                uint256(liquidity)
            );
        }

        // Settle deltas
        if (delta0 < 0)
            key.currency0.settle(
                manager,
                address(this),
                uint256(-delta0),
                false
            );
        if (delta1 < 0)
            key.currency1.settle(
                manager,
                address(this),
                uint256(-delta1),
                false
            );
        if (delta0 > 0)
            key.currency0.take(manager, address(this), uint256(delta0), false);
        if (delta1 > 0)
            key.currency1.take(manager, address(this), uint256(delta1), false);

        poolToLPStartTime[id] = block.timestamp;
    }

    /////////////////////////////////////
    // Post-Migration Fee Splitter     //
    /////////////////////////////////////

    function collectAndDistributeFees(PoolKey calldata key) external {
        PoolId id = key.toId();
        if (!migrated[id]) revert POOL_NOT_MIGRATED();

        // Collect accrued fees by modifying liquidity with 0 delta
        int deltaBefore0 = manager.currencyDelta(address(this), key.currency0);
        int deltaBefore1 = manager.currencyDelta(address(this), key.currency1);

        (BalanceDelta feeDelta, ) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: 0,
                salt: 0
            }),
            ""
        );

        int deltaAfter0 = manager.currencyDelta(address(this), key.currency0);
        int deltaAfter1 = manager.currencyDelta(address(this), key.currency1);

        uint256 fees0 = deltaAfter0 > deltaBefore0
            ? uint256(deltaAfter0 - deltaBefore0)
            : 0;
        uint256 fees1 = deltaAfter1 > deltaBefore1
            ? uint256(deltaAfter1 - deltaBefore1)
            : 0;

        if (fees0 == 0 && fees1 == 0) revert NO_FEES_TO_COLLECT();

        FeeConfig memory cfg = feeConfig[id];
        uint256 totalBps = cfg.protocolFeeBps +
            cfg.creatorFeeBps +
            cfg.lpRewardBps;

        // Split fees for each currency
        if (fees0 > 0) {
            _splitFee(key.currency0, fees0, id, cfg, totalBps);
        }
        if (fees1 > 0) {
            _splitFee(key.currency1, fees1, id, cfg, totalBps);
        }
    }

    function _splitFee(
        Currency currency,
        uint256 feeAmount,
        PoolId id,
        FeeConfig memory cfg,
        uint256 totalBps
    ) internal {
        uint256 protocolAmount = (feeAmount * cfg.protocolFeeBps) / totalBps;
        uint256 creatorAmount = (feeAmount * cfg.creatorFeeBps) / totalBps;
        // lpReward = remainder (stays in pool, nothing to transfer)

        if (protocolAmount > 0) {
            currency.transfer(platformTreasury[id], protocolAmount);
        }
        if (creatorAmount > 0) {
            currency.transfer(creatorWallet[id], creatorAmount);
        }
        // LP rewards portion is implicitly left in the pool
    }

    /////////////////////////////////
    // Tax Revenue Claim Functions //
    /////////////////////////////////

    function claimCreatorFees(PoolKey calldata key) external {
        PoolId id = key.toId();
        if (msg.sender != creatorWallet[id]) revert UNAUTHORIZED();
        uint256 amount = creatorAccrued[id];
        if (amount == 0) revert NO_FEES_TO_COLLECT();
        creatorAccrued[id] = 0;
        Currency.wrap(TOKEN_ADDRESS).transfer(msg.sender, amount);
    }

    function claimPlatformFees(PoolKey calldata key) external {
        PoolId id = key.toId();
        if (msg.sender != platformTreasury[id]) revert UNAUTHORIZED();
        uint256 amount = platformAccrued[id];
        if (amount == 0) revert NO_FEES_TO_COLLECT();
        platformAccrued[id] = 0;
        Currency.wrap(TOKEN_ADDRESS).transfer(msg.sender, amount);
    }

    //////////////////////////
    // Liquidity Management //
    //////////////////////////

    function addLiquidity(
        AddLiquidityParams calldata params
    ) external returns (uint128 liquidity) {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert POOL_NOT_INITIALIZED();

        liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(
                TickMath.minUsableTick(key.tickSpacing)
            ),
            TickMath.getSqrtPriceAtTick(
                TickMath.maxUsableTick(key.tickSpacing)
            ),
            params.amount0Desired,
            params.amount1Desired
        );

        BalanceDelta addedDelta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: liquidity.toInt256(),
                salt: 0
            })
        );

        UniswapV4ERC20(poolLpToken[poolId]).mint(params.to, liquidity);

        if (
            uint128(-addedDelta.amount0()) < params.amount0Min ||
            uint128(-addedDelta.amount1()) < params.amount1Min
        ) {
            revert TOO_MUCH_SLIPPAGE();
        }
    }

    function removeLiquidity(
        RemoveLiquidityParams calldata params
    ) public virtual returns (BalanceDelta delta) {
        PoolKey memory key = PoolKey({
            currency0: params.currency0,
            currency1: params.currency1,
            fee: params.fee,
            tickSpacing: 60,
            hooks: IHooks(address(this))
        });

        PoolId poolId = key.toId();

        (uint160 sqrtPriceX96, , , ) = manager.getSlot0(poolId);

        if (sqrtPriceX96 == 0) revert POOL_NOT_INITIALIZED();

        UniswapV4ERC20 erc20 = UniswapV4ERC20(poolLpToken[poolId]);

        delta = modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(key.tickSpacing),
                tickUpper: TickMath.maxUsableTick(key.tickSpacing),
                liquidityDelta: -(params.liquidity.toInt256()),
                salt: 0
            })
        );

        erc20.burn(msg.sender, params.liquidity);
    }

    function modifyLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) internal returns (BalanceDelta delta) {
        delta = abi.decode(
            manager.unlock(abi.encode(CallbackData(msg.sender, key, params))),
            (BalanceDelta)
        );
    }

    function _unlockCallback(
        bytes calldata rawData
    ) internal override onlyPoolManager returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        BalanceDelta delta;

        if (data.params.liquidityDelta < 0) {
            delta = _removeLiquidity(data.key, data.params);
            _takeDeltas(data.sender, data.key, delta);
        } else {
            (delta, ) = manager.modifyLiquidity(
                data.key,
                data.params,
                bytes("")
            );
            _settleDeltas(data.sender, data.key, delta);
        }
        return abi.encode(delta);
    }

    function _removeLiquidity(
        PoolKey memory key,
        IPoolManager.ModifyLiquidityParams memory params
    ) internal returns (BalanceDelta delta) {
        PoolId poolId = key.toId();

        uint256 liquidityToRemove = FullMath.mulDiv(
            uint256(-params.liquidityDelta),
            manager.getLiquidity(poolId),
            UniswapV4ERC20(poolLpToken[poolId]).totalSupply()
        );

        params.liquidityDelta = -(liquidityToRemove.toInt256());
        (delta, ) = manager.modifyLiquidity(key, params, bytes(""));
    }

    function _settleDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        key.currency0.settle(
            manager,
            sender,
            uint256(int256(-delta.amount0())),
            false
        );
        key.currency1.settle(
            manager,
            sender,
            uint256(int256(-delta.amount1())),
            false
        );
    }

    function _takeDeltas(
        address sender,
        PoolKey memory key,
        BalanceDelta delta
    ) internal {
        manager.take(key.currency0, sender, uint256(uint128(delta.amount0())));
        manager.take(key.currency1, sender, uint256(uint128(delta.amount1())));
    }

    ///////////////
    // Utilities //
    ///////////////

    function getCurrencies(
        IPoolManager.SwapParams calldata params,
        PoolKey calldata key,
        bool exactInput
    ) internal pure returns (Currency specified, Currency unspecified) {
        return
            (params.zeroForOne == exactInput)
                ? (key.currency0, key.currency1)
                : (key.currency1, key.currency0);
    }

    function getSpecifiedAmount(
        IPoolManager.SwapParams calldata params,
        bool exactInput
    ) internal pure returns (uint256) {
        return
            exactInput
                ? uint256(-params.amountSpecified)
                : uint256(params.amountSpecified);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SENDER_MUST_BE_HOOK();

        return ExponentialLaunchpad.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override returns (bytes4) {
        if (sender != address(this)) revert SENDER_MUST_BE_HOOK();

        return ExponentialLaunchpad.beforeRemoveLiquidity.selector;
    }
}

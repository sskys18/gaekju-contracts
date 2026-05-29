// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { IOracleAdapter } from "./interfaces/IOracleAdapter.sol";
import { FixedPointMath } from "./libraries/FixedPointMath.sol";

interface IMockPyth {
    struct PriceData {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PriceData memory);
    function updatePriceFeeds(bytes[] calldata data) external payable;
    function getUpdateFee(bytes[] calldata data) external view returns (uint256);
}

contract OracleAdapter is IOracleAdapter, UUPSUpgradeable, AccessControlUpgradeable {
    error StalePrice();
    error NegativePrice();
    error ConfidenceTooWide();
    error MarketNotConfigured();

    /// @dev Max confidence / price ratio: 1% = 1e16 in 18-dec
    uint256 internal constant MAX_CONFIDENCE_RATIO = 1e16;

    struct MarketOracle {
        bytes32 pythPriceId;
        uint256 stalenessThreshold;
    }

    IMockPyth public pyth;

    mapping(uint256 => MarketOracle) public marketOracles;
    // Path B: sequencer-fed mid (wired via FundingRate in Task 8). Slot kept for storage compat.
    mapping(uint256 => address) public __deprecated_orderBooks;
    mapping(uint256 => uint256) public tickSizes; // cached from MarginEngine config

    uint256[50] private __gap;

    function initialize(address _pyth, address _admin) external initializer {
        pyth = IMockPyth(_pyth);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function setMarketOracle(uint256 marketId, bytes32 pythPriceId, uint256 stalenessThreshold)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        marketOracles[marketId] = MarketOracle(pythPriceId, stalenessThreshold);
    }

    function setTickSize(uint256 marketId, uint256 tickSize) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tickSizes[marketId] = tickSize;
    }

    function getIndexPrice(uint256 marketId) public view returns (uint256) {
        return _getOraclePrice(marketId);
    }

    function getMarkPrice(uint256 marketId) public view returns (uint256) {
        // Path B: mid-price blend will be wired via FundingRate sequencer mid in Task 8.
        // Until then, mark == oracle index (70/30 blend reattaches once FundingRate lands).
        return _getOraclePrice(marketId);
    }

    function updatePrice(uint256 marketId, bytes[] calldata priceUpdateData) external payable {
        uint256 fee = pyth.getUpdateFee(priceUpdateData);
        pyth.updatePriceFeeds{ value: fee }(priceUpdateData);
        emit PriceUpdated(marketId, _getOraclePrice(marketId), block.timestamp);
    }

    function _getOraclePrice(uint256 marketId) internal view returns (uint256) {
        MarketOracle memory mo = marketOracles[marketId];
        if (mo.pythPriceId == bytes32(0)) revert MarketNotConfigured();

        IMockPyth.PriceData memory p = pyth.getPriceNoOlderThan(mo.pythPriceId, mo.stalenessThreshold);

        if (p.price <= 0) revert NegativePrice();

        // Check confidence band: conf/price < 1%
        uint256 absPrice = uint256(uint64(p.price));
        uint256 confRatio = (uint256(p.conf) * 1e18) / absPrice;
        if (confRatio > MAX_CONFIDENCE_RATIO) revert ConfidenceTooWide();

        // Convert Pyth price to 18-decimal
        return _pythTo18Dec(p.price, p.expo);
    }

    /// @dev Convert Pyth price (int64 * 10^expo) to 18-decimal uint256.
    function _pythTo18Dec(int64 price, int32 expo) internal pure returns (uint256) {
        uint256 absPrice = uint256(uint64(price));
        if (expo >= 0) {
            return absPrice * (10 ** uint32(expo)) * 1e18;
        } else {
            uint32 negExpo = uint32(-expo);
            if (negExpo <= 18) {
                return absPrice * (10 ** (18 - negExpo));
            } else {
                return absPrice / (10 ** (negExpo - 18));
            }
        }
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) { }
}

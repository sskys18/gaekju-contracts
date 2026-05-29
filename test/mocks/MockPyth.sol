// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

contract MockPyth {
    struct PriceData {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    mapping(bytes32 => PriceData) public prices;

    function setPrice(bytes32 id, int64 price, uint64 conf, int32 expo) external {
        prices[id] = PriceData({ price: price, conf: conf, expo: expo, publishTime: block.timestamp });
    }

    function setPriceWithTimestamp(bytes32 id, int64 price, uint64 conf, int32 expo, uint256 ts) external {
        prices[id] = PriceData({ price: price, conf: conf, expo: expo, publishTime: ts });
    }

    function getPriceNoOlderThan(bytes32 id, uint256 age) external view returns (PriceData memory) {
        PriceData memory p = prices[id];
        require(p.publishTime >= block.timestamp - age, "stale price");
        require(p.price > 0, "invalid price");
        return p;
    }

    function getPriceUnsafe(bytes32 id) external view returns (PriceData memory) {
        return prices[id];
    }

    function updatePriceFeeds(bytes[] calldata) external payable { }

    function getUpdateFee(bytes[] calldata) external pure returns (uint256) {
        return 0;
    }
}

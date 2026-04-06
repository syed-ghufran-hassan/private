
interface IWrappedHlpDepositor {
    function deposit(address depositAsset, uint256 depositAmount, uint256 minimumMint, address to, bytes calldata communityCode) external;
}
(async () => {
    const bidAmount = ethers.utils.parseEther("0.05");
    const salt = ethers.utils.formatBytes32String("secret123");
    const bidderAddress = "0xCbe6f003fd88A264F6f7618f11F221Cbc1825C08";
    const contractAddress = "0x61816d73e0200Dd2e975F6eA282b3BA77c9DE85b";

    const hash = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
            ["uint256", "bytes32", "address", "address"],
            [bidAmount, salt, bidderAddress, contractAddress]
        )
    );

    console.log("bidAmount (Wei):", bidAmount.toString());
    console.log("salt:", salt);
    console.log("HASH:", hash);
})();



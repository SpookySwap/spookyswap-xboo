import { ethers, run } from "hardhat"

boo = "0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE"
wftm = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
factory = "0x152eE697f2E276fA89E96742e9bB9aB1F2E61bE3"
xboo = "0xa48d959AE2E88f1dAA7D5F611E01908106dE7598"

async function main() {
    const brewBoo = await ethers.getContractFactory("BrewBoo");
    BrewBoo = await brewBoo.deploy(factory, BooMirrorWorld.address, boo, wftm);
    await BrewBoo.deployed()
    console.log("BrewBoo deployed to:", BrewBoo.address);

    await run("verify:verify", {
      address: BrewBoo.address,
      constructorArguments: [factory, BooMirrorWorld.address, boo, wftm],
  })
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });

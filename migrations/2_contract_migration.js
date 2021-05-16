const BooMirrorWorld = artifacts.require("BooMirrorWorld");
const BrewBoo = artifacts.require("BrewBoo");

boo = "0x841FAD6EAe12c286d1Fd18d1d525DFfA75C7EFFE"
wftm = "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83"
factory = "0x152eE697f2E276fA89E96742e9bB9aB1F2E61bE3"

module.exports = function (deployer) {

  deployer.deploy(BooMirrorWorld, boo).then(function() {
    return deployer.deploy(BrewBoo, factory, BooMirrorWorld.address, boo, wftm)
  })
};

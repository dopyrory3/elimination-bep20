const iface = new ethers.utils.Interface(["function initialize(address)"]);
const data = iface.encodeFunctionData("initialize", ["0x580eBc25a7b254dD133B573F369003736270806C"]);
console.log(data);

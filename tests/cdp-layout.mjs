const endpoint = process.argv[2];
if (!/^ws:\/\//.test(endpoint || "")) throw new Error("Missing CDP websocket endpoint");
const socket = new WebSocket(endpoint);
const result = await new Promise((resolve, reject) => {
  const timer = setTimeout(() => reject(new Error("CDP timeout")), 10000);
  socket.addEventListener("open", () => socket.send(JSON.stringify({
    id: 1,
    method: "Runtime.evaluate",
    params: {
      returnByValue: true,
      expression: `JSON.stringify((()=>{const rect=s=>{const e=document.querySelector(s),r=e?.getBoundingClientRect();return r?{x:r.x,right:r.right,width:r.width}:null};return{innerWidth,scrollWidth:document.documentElement.scrollWidth,page:rect('#page-discussion'),head:rect('.discussion-head'),layout:rect('.discussion-layout'),compose:rect('.discussion-compose'),item:rect('.discussion-item'),topActions:rect('.top-actions'),topStyle:getComputedStyle(document.querySelector('.top-actions')).cssText}})())`
    }
  })));
  socket.addEventListener("message", event => {
    const message = JSON.parse(event.data);
    if (message.id === 1) { clearTimeout(timer); resolve(message.result); }
  });
  socket.addEventListener("error", reject);
});
socket.close();
console.log(JSON.stringify(result));

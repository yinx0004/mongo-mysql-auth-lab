// Background writer for scenario 06. Inserts into shop.ticks about 10 times a
// second and prints one summary line per second: ok/err counts and last error.
// Env: W (writer name), SECS (how long to run).
const name = process.env.W || "writer";
const end = Date.now() + Number(process.env.SECS || 600) * 1000;
let ok = 0, err = 0, last = "", tick = Date.now();
while (Date.now() < end) {
  try {
    db.getSiblingDB("shop").ticks.insertOne({w: name, at: new Date()});
    ok++;
  } catch (e) {
    err++;
    last = e.message;
  }
  if (Date.now() - tick >= 1000) {
    print(`${new Date().toISOString()} ok=${ok} err=${err} ${last}`);
    ok = 0; err = 0; last = ""; tick = Date.now();
  }
  sleep(100);
}

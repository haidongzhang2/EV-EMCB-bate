// Requires the Big library
FirebasePushID <- {
  // Push ID Generation
  PUSH_CHARS = "-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ_abcdefghijklmnopqrstuvwxyz", // Modeled after base64 web-safe chars, but ordered by ASCII.
  _lastPushTime = 0,          // Timestamp of last generated Push ID, used to prevent local collisions if you push twice in one ms.
  _lastRandChars = array(12), // We generate 72-bits of randomness which get turned into 12 characters and appended to the
                              // timestamp to prevent collisions with other clients.  We store the last characters we
                              // generated because in the event of a collision, we'll use those same characters except
                              // "incremented" by one.
  /**
   * Fancy ID generator that creates 20-character string identifiers with the following properties:
   *
   * 1. They're based on timestamp so that they sort *after* any existing ids.
   * 2. They contain 72-bits of random data after the timestamp so that IDs won't collide with other clients' IDs.
   * 3. They sort *lexicographically* (so the timestamp is converted to characters that will sort properly).
   * 4. They're monotonically increasing.  Even if you generate more than one in the same timestamp, the
   *    latter ones will sort after the former ones.  We do this by using the previous random bits
   *    but "incrementing" them by 1 (only in the case of a timestamp collision).
   */
   //TODO: should we use the full precision including the usecs?
  generate = function(ts=null) {
    local now;

    // Need to get to an epoch integer time in milliseconds
    if(typeof(ts) == "integer") { // Only have 32 bits of integer epoch time - need to add milliseconds
      now = Big(ts).times(1000);
    } else if(typeof(ts) == "table" && "time" in ts) {  // probably have a date() object
      now = Big(ts.time).times(1000);
      if("usec" in ts)  // hopefully from the agent instead of the device
          now = now.plus(Big(ts.usec).div(1000))
    } else if(typeof(ts) == "string") { //JS new Date().getTime()
      now = Big(ts);
    } else {  // No argument supplied
      ts = date();
      now = Big(ts.time).times(1000).plus(Big(ts.usec).div(1000))
    }

    now = Big(now.toFixed(0)) //Get rid of usecs if we have them (JS only goes to milliseconds)
    now.DP = 0;

    local duplicateTime = now.eq(_lastPushTime)
    _lastPushTime = now;

    local timeStampChars = array(8);
    for (local i = 7; i >= 0; i--) {
      local char = now.mod(64).toString().tointeger();
      timeStampChars[i] = PUSH_CHARS[char].tochar();
      // NOTE: Can't use << here because javascript will convert to int and lose the upper bits.
      now = Big(now.minus(char).div(64));

    }
    if (!now.eq(0)) {
        throw("We should have converted the entire timestamp.");
    }
    local id = timeStampChars.reduce(function(previousValue, currentValue){
           return (previousValue.tostring() + currentValue.tostring());
       }).tostring();

    if (!duplicateTime) {
      for (local i = 0; i < 12; i++) {
        _lastRandChars[i] = math.floor((1.0 * math.rand() / RAND_MAX) * (63 + 1));
      }
    } else {
      // If the timestamp hasn't changed since last push, use the same random number, except incremented by 1.
      local i
      for (i = 11; i >= 0 && _lastRandChars[i] == 63; i--) {
        _lastRandChars[i] = 0;
      }
      _lastRandChars[i]++;
    }
    for (local i = 0; i < 12; i++) {
      id += PUSH_CHARS[_lastRandChars[i]].tochar();
    }
    if(id.len() != 20) throw "Length should be 20.";

    return id;
  },

  startAtStringForTimestamp = function(ts=null){
    local str = this.generate(ts).slice(0,8);
    for(local i=8; i < 20; i++){
      str += PUSH_CHARS[0].tochar()
    }
    return str
  }

  getTimestamp = function(id) {
    local time = Big(0);

    for (local i = 0; i < 8; i++) {
      time = time.mul(64).plus(PUSH_CHARS.find(id[i].tochar()));
    }

    // Proof by cosmo - not really sure why this is necessary...
    time.sub(1000)

    return time.toString();
  },

  getTimestampInSeconds = function(id) {
    server.log("Getting timestamp in seconds for timestamp: "+id);
    return Big(getTimestamp(id)).div(1000).toString().tointeger();
  }

  getDate = function(id) {
      local ts = Big(getTimestamp(id));
      local intSeconds = ts.div(1000).toFixed(0).tointeger();
      local usecs = ts.minus(Big(intSeconds).times(1000)).times(1000).toString().tointeger() + 1000000

      // This has to do with rounding timestamps up or down in our division and toFixed calls
      if(usecs >= 1000000){
          usecs -= 1000000
      } else {
          intSeconds--
      }

      local d = date(intSeconds );
      d.usec = usecs
      // usec is only accurate to the millisecond but its as close as we can get based on how much data we are packing in...
      return d
  }

}


// Tests
/*for(local i=0; i< 10; i++){
    local ts = date();
    local now = Big(ts.time).times(1000).plus(Big(ts.usec).div(1000)).toFixed(0);
    local pushID = FirebasePushID.generate(now)
    server.log(now + ", " + FirebasePushID.getTimestamp(pushID) + ", " + (now == FirebasePushID.getTimestamp(pushID)).tostring() + ", " + Big(now).sub(FirebasePushID.getTimestamp(pushID)).toString() + ", " + pushID)
}

for(local i=0; i< 10; i++){
    local now = "1423088131153"
    local pushID = FirebasePushID.generate(now)
    server.log(now + ", " + FirebasePushID.getTimestamp(pushID) + ", " + (now == FirebasePushID.getTimestamp(pushID)).tostring() + ", " + Big(now).sub(FirebasePushID.getTimestamp(pushID)).toString() + ", " + pushID)
}

server.log("Should log 1423088131153")
server.log("           " + FirebasePushID.getTimestamp("-JhLeOlGIEjaIOFHR0xd"))

local now = date();
server.log(JSONEncoder.encode(now))
server.log(JSONEncoder.encode(FirebasePushID.getDate(FirebasePushID.generate(now))))*/


/*local now = date()
server.log(FirebasePushID.generate(now))
server.log(FirebasePushID.startAtStringForTimestamp(now))
server.log(JSONEncoder.encode(now))
server.log(JSONEncoder.encode(FirebasePushID.getDate(FirebasePushID.generate(now))))
server.log(JSONEncoder.encode(FirebasePushID.getDate(FirebasePushID.startAtStringForTimestamp(now))))
server.log(JSONEncoder.encode(FirebasePushID.getTimestamp(FirebasePushID.generate(now))))
server.log(JSONEncoder.encode(FirebasePushID.getTimestamp(FirebasePushID.startAtStringForTimestamp(now))))*/

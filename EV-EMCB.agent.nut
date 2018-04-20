
// === INCLUDES ================================================================
@include once "src/EMCBConstants.nut"
@include once "src/EMCBConstants.agent.nut"
@include once "lib/LibraryConstants.device.nut"
@include once "lib/ETN_StandardLib/ETN_StandardLib.class.agent.nut"
@include once "lib/Big/Big.class.nut"
@include once "lib/UINT64/UInt64.class.nut"
@include once "lib/ImpWrapper/ImpWrapper.class.nut"
@include once "lib/ImpWrapper/ImpWithMasterTimer.class.nut"
@include once "lib/ImpWrapper/loggingHTTP.class.nut"
@include once "lib/UINT64/TimestampUInt64.class.nut"
@include once "lib/Promise/promise.class.nut"
@include once "lib/Promise/promiseExtended.class.nut"
@include once "lib/TimeHelpers/TimeHelpers.class.nut"
@include once "lib/Timer/Timer.class.nut"
@include once "lib/JSONLiteralString/JSONLiteralString.class.nut"
@include once "lib/JSONEncoder/JSONEncoder.class.nut"
@include once "lib/JSONParser/JSONParser.class.nut"
@include once "lib/PrettyPrinter/PrettyPrinter.class.nut"
@include once "lib/BuildAPI/BuildAPI.class.agent.nut"
@include once "lib/Rocky/Rocky.class.nut"
@include once "lib/Rocky/RockyStatistics.class.nut"
@include once "lib/MessageManager/MessageManager.class.nut"
@include once "lib/MessageManager/MessageManagerExtended.class.nut"
@include once "lib/RPC/RPC.class.nut"
@include once "lib/Serializer/Serializer.class.nut"
//
@include once "lib/Firebase/firebase.agent.nut"
@include once "lib/Firebase/FirebasePushId.class.agent.nut"
@include once "lib/JSONWebToken/JSONWebToken.class.nut"
@include once "lib/ImpWrapper/httpRequestWithTimeout.agent.nut"
@include once "lib/FirebasePusher/FirebasePusher.class.agent.nut"
@include once "src/FirebaseHTTPResponse.class.agent.nut"

@include once "lib/AWSRequestV4/AWSRequestV4.class.nut"
@include once "lib/AWSKinesisFirehose/AWSKinesisFirehose.class.nut"
@include once "lib/AWSKinesisFirehose/AWSKinesisFirehosePusher.class.nut"
//
@include once "src/Rocky/middlewareProfileFirebaseLatency.agent.nut"
@include once "src/Rocky/middlewareAuthorization.agent.nut"
@include once "src/Rocky/middlewareValidation.agent.nut"
//
@include once "lib/Commissioning/Workflows/AddDevice.agent.nut"
@include once "lib/Commissioning/Workflows/DecomissionSite.agent.nut"
@include once "lib/Commissioning/Workflows/NewSite.agent.nut"
@include once "lib/Commissioning/Workflows/RemoveDevice.agent.nut"
@include once "lib/Commissioning/Workflows/ReplaceDevice.agent.nut"
@include once "lib/Commissioning/Workflows/ReplaceHotspot.agent.nut"
@include once "lib/Commissioning/Commissioning.agent.nut"
// DataManager Events
@include once "lib/DataManager/Generated/DataManager.events.device.nut"
//
//TODO: need to update energybuckets and intervaldata to be totally Firebase-promise based
@include once "lib/EnergyBuckets/EnergyBuckets.class.agent.nut"
@include once "lib/IntervalData/IntervalData.class.agent.nut"
//

@include once "lib/AgentStorage/AgentStorage.class.nut"
@include once "lib/DemandResponse/DemandResponse.constants.nut"
@include once "lib/DemandResponse/DemandResponse.agent.nut"
@include once "lib/ETN_EVSE/ETN_EVSE.plugsessions.agent.nut"

// =============================================================================
// MAIN_APPLICATION_CODE -------------------------------------------------------
// ============================================================================{

// =============================================================================
// GLOBAL_VARIABLES ------------------------------------------------------------
// ============================================================================{

/**
 * Override HTTP so that we have some extra logging and statistics
 */
// http <- loggingHTTP(http, 300, STATS_UPDATE_INTERVAL, false);

/**
 * We override our imp class so that we can limit our number of "real" imp.wakeup timers to 20, which is all that the agent will provide
 */
imp <- ImpWithMasterTimer();

/**
 * Our Agent ID wherever it is needed throughout the code.  For some reason imp
 * doesn't give us an easier way to access it...
 * @property g_idAgent
 */
g_idAgent <- split(http.agenturl(), "/")[2];

/**
 * Our unique device ID to be used throughout the code
 * @property g_idDevice
 */
g_idDevice <- imp.configparams.deviceid;	//This is such a goofy way to get this, but at least we don't have to wait for the device to send it to us!

// Setup our agent storage and all of its defaults
g_db <- AgentStorage();
@include once "src/AgentStorageDefaults.nut"

/*server.log("========================== BOOTING ===========================")
g_Build <- BuildAPIAgent("c690f3c9ebcfcad0723735fba621c920"); //EMCB_beta_temp   //TODO: BUG: replace with build time preprocess constant
g_Build.getModelName()
       //.then(g_Build.getLatestBuildNumber.bindenv(g_Build))    //Can use this version if you don't want the model name logged
       .then(function(modelName){
           server.log("Model: " + modelName)
           return g_Build.getLatestBuildNumber(modelName)
       })
       .then(function(buildVersion){
               server.log("Build: " + buildVersion);
       })
       .fail(function(error){
           server.error("UNABLE TO GET BUILDVERSION VIA BUILDAPI")
           server.error(error)
       })*/

// DataPush Events
// @include once "lib/Datapush/Generated/DataPush.events.device.nut"


/**
 * Global reference to our Rocky instance, which manages all of our APIs.
 * @method Rocky
 */
 g_Rocky  <-  Rocky({
     accessControl = false,
     allowUnsecure = false,
     strictRouting = false,
     timeout = 10,
     // disableOnRequest = true
 });

g_Rocky.use([middlewareProfileFirebaseLatency]);
//TODO: we need some global midllewares that somehow protect us from bad implementation...  They should ensure that we have called both our auth and validate middleware on the individual paths...


/**
 * Global instantiation of MessageManager
 * @method MessageManager
 */
 // g_MM <- MessageManagerStatistics(null, g_db, STATS_UPDATE_INTERVAL);
 g_MM <- MessageManagerExtended();

 g_MM.on("rpc", rpcExec);

 g_RPCMask <- {
   "g_Breaker.open": "breakerOpen",
   "g_Breaker.close": "breakerClose",
   "g_Breaker.toggle": "breakerToggle"
 }

 g_MM.beforeOnReply(function(message, data){
   if (typeof message.metadata == TYPE_TABLE && "rockyContext" in message.metadata) {
     local context = message.metadata.rockyContext;

     //Set X-Source header
     context.res.headers["X-Source"] <- "device";

     //Set X-Device-Latency header for latency profiling (for now, always do this even if "X-Profile-Latency" isn't included in request headers)
     local latency = TimestampUInt64().sub(message.metadata.millis);
     context.res.headers["X-Device-Latency"] <- latency;

     /*if ("req" in context && "headers" in context.req && ("X-Profile-Latency" in context.req.headers || "x-profile-latency" in context.req.headers)) {
       // Check to see if we should be doing all of the latency calcs or not
     }*/
   }
 });

 g_MM.onTimeout(function(message, wait, fail){
     if (typeof fail == TYPE_FUNCTION) {
         fail();
     }
 })

 //convert known headers that are millisecond epochs to uints
 function checkAndConvertHeaders(value, type, key) {
   if (type == "number") {
     if (key == "X-Firebase-Request-Timestamp" || key == "X-Client-Request-Timestamp") {
       return uint64(value)
     } else {
       return value.find(".") == null ? value.tointeger() : value.tofloat()
     }
   } else {
     return value;
   }
 }

// https://www.firebase.com/docs/web/guide/login/custom.html#section-tokens-without-helpers
/*Firebase app JWTs can also be generated with any existing JWT generation library and then signed by a SHA-256 HMAC signature.
When using an existing library, a Firebase app auth token must contain the following claims:
| Claim | Description                                                                                                                                 |   |
|-------|---------------------------------------------------------------------------------------------------------------------------------------------|---|
| v     | The version of the token. Set this to the number 0.                                                                                         |   |
| iat   | The "issued at" date as a number of seconds since the Unix epoch.                                                                           |   |
| d     | The authentication data. This is the payload of the token that will become visible as the auth variable in the Security and Firebase Rules. |   |

The following claims are optional when using an authentication token:
| Claim | Description                                                                                                                                                          |   |
|-------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------|---|
| nbf   | The token "not before" date as a number of seconds since the Unix epoch. If specified, the token will not be considered valid until after this date.                 |   |
| exp   | The token expiration date as a number of seconds since the Unix epoch. If not specified, by default the token will expire 24 hours after the "issued at" date (iat). |   |
| admin | Set to true to make this an "admin" token, which grants full read and write access to all data.                                                                      |   |
| debug | Set to true to enable debug mode, which provides verbose error messages when Security and Firebase Rules fail.                                                       |   |
*/
/**
 * This is our global reference to the root of our Firebase.  Through this reference
 * all data should be written out.  This reference is also what is used to stream
 * our unique device REST API Proxy.
 * @property g_FbRef
 */
g_FbRef <- Firebase(FIREBASE_DB,
                    JSONWebToken.sign({
                          "v": 0
                          "d": {
                            "id": "agent",
                            "uid": g_idAgent
                          }
                          "debug": true //TODO: Remove this once we get everything squared away with Firebase
                        },
                        FIREBASE_SECRET,
                        { "algorithm": "HS256", "issuer": false, "expiresInSeconds": (2147483647 - time()) }   //TODO: BUG: Token will expire at 03:14:07 UTC on 19 January 2038 - this is the largest number that an imp agent can deal with without using the Big Library.  THIS CODE AND THE JWT CODE MUST BE UPDATED BEFORE THEN.
                        // { "algorithm": "HS256", "issuer": false, "expiresInSeconds": 5 }
                    )
);

g_FirehosePusher <- AWSKinesisFirehosePusher("us-west-2", AWS_FIREHOSE_ACCESS_KEY_ID, AWS_FIREHOSE_SECRET_ACCESS_KEY);

//Put all EV EMCBs on this model onto an RWDD account for debugging
//Create association from device to user
/*local uid = "b4483bef-c54c-430d-9075-87189e7df9bf" //rwdd@eaton.com
g_FbRef.write("/v1/devices/" + g_idAgent + "/owners/" + uid, true)

//Create association from user to device
g_FbRef.write("/v1/users/" + uid + "/devices/" + g_idAgent, true)*/

//Middleware for checking the response before the response handler is called
//NOTE: This is middleware for checking the response before the response handler
//      is called. This is now where we do our logging for unauthorized
//      requests, so other redundant logs throughout the codebase have been
//      removed.
g_FbRef.beforeDataReceived(function(req, res){
  //Check the statuscode and change error count accordingly
  if ((200 <= res.statuscode && res.statuscode < 300) || res.statuscode == 18 || res.statuscode == 401 || res.statuscode == 429) {
    // g_FBNumErrors = 0;
    if (res.statuscode == 401) printObject({"req": req, "res": res})
  } else { //really we should just be incrementing when we get res.statuscode == 0
    // g_FBNumErrors++;
    if (res.statuscode != 0) printObject({"req": req, "res": res})
  }
})

function onFirebaseFailureFactory(calledFrom=null, reject=null, reply=null, context=null){
  return function(data){
    try {
      local err = data.err;
      local body = ("body" in data.request ? data.request.body : null);
      local path = ("path" in data.request ? data.request.path : null);

      // server.error((calledFrom ? "["+calledFrom+"]: " : "")+"Error sending data to Firebase: \""+err+"\"")
      if (reject) reject({"success": false, "code": FIREBASE_ERROR, "data": err}); reject = null;
      if (reply) reply({"success": false, "code": FIREBASE_ERROR, "data": err}); reply = null;
    } catch (e) {
      if (reject) reject({"success": false, "code": FIREBASE_ERROR, "data": e});
      if (reply) reply({"success": false, "code": FIREBASE_ERROR, "data": e});
    }

    return Promise.reject(data)
  }
}


g_FbPusher <- FirebasePusher(g_FbRef); //once a sec
g_FbPusherStats <- FirebasePusher(g_FbRef, STATS_UPDATE_INTERVAL); //once every 60s

g_EnergyBuckets <- EnergyBuckets(g_db, g_db.read(NUM_POLES), g_db.read(POLE_1_PHASE), g_db.read(GMT_OFFSET));
g_IntervalDataManager <- IntervalData(g_db);

// =============================================================================
// -------------------------------------------------------- END_GLOBAL_VARIABLES
// ============================================================================}

function setUIDs(){
  local fbUpdate = {};

  g_MM.send("rpc", ["g_DataManager.updateData", ["devices", "staticData", "idAgent", g_idAgent]]);

  fbUpdate["/v1/devices/" + g_idAgent + "/staticData/idDevice"] <- { "val": g_idDevice, "ts": time() };
  fbUpdate["/v1/devices/activeAgent/" + g_idDevice] <- g_idAgent;
  g_FbRef.update("/", fbUpdate)
  .fail(function(err){
    // server.error("Failed to set UID Associations!!!")
    // printObject(err);
    imp.wakeup(10, setUIDs);
  })
}

function replacePoleWithPhase(pole, pole1Phase="A") {
  if (pole == "0" || pole == 0) {
    return pole1Phase;
  } else if (pole == "1" || pole == 1) {
    if (pole1Phase == "A") return "B";
    else if (pole1Phase == "B") return "A";
  }
}

@if METER_PROTOCOL_REV == 2.06
g_WaveformTimer             <- imp.wakeup(0.0, function(){});
g_WaveformPushID            <- null;
g_WaveformTS                <- null;
g_WaveformExpectingType     <- null;
g_WaveformTriggerStartTime       <- null;
g_WaveformTriggerStartTime  <- null;
g_WaveformTriggerEndTime    <- null;
@end

function waveformCalculateTriggerWindow(options) {
    local window              = { "start": null, "end": null };
    local delta               = options.delta;
    local samplesAfterTrigger = options.samplesAfterTrigger;
    local duration            = options.duration;
    local captureEnd          = options.captureEnd;
    local type                = options.type; //waveform or highRate
    local triggerTypes        = options.triggerTypes;
    local log                 = "log" in options ? options.log : false;

    if (triggerTypes.find("Immediate") != null) {
        window["end"]   = captureEnd.sub(samplesAfterTrigger * delta);
        window["start"] = window["end"];
    } else {
        //Calculate triggerEndTime (triggerEndTime == endTime - (samplesAfterTrigger*deltaTime))
        window["end"] = captureEnd.sub(samplesAfterTrigger * delta);
        if (log) server.log("triggerEndTime == captureEnd - (samplesAfterTrigger*deltaTime)")
        if (log) server.log(window["end"].toString() +" == "+ captureEnd.toString() + " - ("+samplesAfterTrigger+"*"+delta+")")

        //Calculate triggerStartTime (triggerStartTime == triggerEndTime - (durationRequired/4))
        window["start"] = window["end"].sub(duration/4);
        if (log) server.log("triggerStartTime == triggerEndTime - (durationRequired/4))");
        if (log) server.log(window["start"].toString() + " == "+ window["end"].toString() + " - ("+duration+"/4)");
    }

    return window;
}

function waveformCalculateCaptureWindow(options) {
    local window                = { "start": null, "end": null };
    local numSamples            = options.numSamples;
    local delta                 = options.delta;
    local samplesAfterTrigger   = "samplesAfterTrigger" in options ? options.samplesAfterTrigger : null;
    local captureEnd            = "captureEnd"          in options ? options.captureEnd          : null;
    local triggerEnd            = "triggerEnd"          in options ? options.triggerEnd          : null;
    local log                   = "log"                 in options ? options.log                 : false;

    if (captureEnd) {
        window["end"] = captureEnd;
    }

    if (triggerEnd) {
        //Calculate capture end time and then start time
        window["end"] = triggerEnd.add(samplesAfterTrigger*delta);
        if (log) server.log("endTime == triggerEndTime + (samplesAfterTrigger*deltaTime)")
        if (log) server.log(window["end"].toString() +" == "+ triggerEnd.toString() + " + ("+samplesAfterTrigger+"*"+delta+")")
    }

    //Calculate startTime (startTime == endTime - (numSamples*deltaTime))
    window["start"] = (window["end"].sub(numSamples * delta))
    if (log) server.log("startTime == endTime + (numSamples*deltaTime)")
    if (log) server.log(window["start"].toString() +" == "+ window["end"].toString() + " - ("+numSamples+"*"+delta+")")

    return window;
}

function parseWaveformData(options) {
    local type              = options.type;
    local data              = options.data;
@if METER_PROTOCOL_REV == 2.06
    local endTime           = "endTime"             in options ? options.endTime            : null; //Assume this is uint64 in MS already
    local triggerStartTime  = "triggerStartTime"    in options ? options.triggerStartTime   : null; //Assume this is uint64 in MS already
    local triggerEndTime    = "triggerEndTime"      in options ? options.triggerEndTime     : null; //Assume this is uint64 in MS already
@else
    local endTime           = options.endTime;
    local triggerStartTime  = null;
    local triggerEndTime    = null;
@end
    local parsedData        = {};
    local tempData          = {}; //used for efficiently rotating data for poles based on pole1Phase
    local pole1Phase        = g_db.read(POLE_1_PHASE) != null ? g_db.read(POLE_1_PHASE) : "A";
    local startTime;        //Capture start time

    for (local i = 0; i < data.numChannels; i++) {
        tempData["Channel"+i] <- [];
    }

    parsedData["sequence"]    <- data.sequence;
    parsedData["duration"]    <- data.duration; //trigger duration (@ 4kHz)
    parsedData["status"]      <- data.status;
    parsedData["triggerType"] <- data.triggerType;
    parsedData["numChannels"] <- data.numChannels;
    parsedData["numSamples"]  <- data.numSamples;
    parsedData["samplesAfterTrigger"] <- data.samplesAfterTrigger;
@if METER_PROTOCOL_REV == 2.06
    parsedData["deltaTime"]   <- (type == "waveform" ? 1 : (50/3)); //1ms is delta for waveform, 16.67ms for highRate data
@else
    parsedData["deltaTime"]   <- 1; //1ms is delta for waveform (1kHz)
@end
    //Decode raw data from device into channels (Channel 0 is mVp0, Channel 1 is mAp0, Channel 2 is mVp1, Channel 3 is mAp1)
    for (local j = 0; j < data.numSamples; j++) {
        for (local i = 0; i < data.numChannels; i++) {
            tempData["Channel"+i].push(data.rawData.readn(INT32));
        }
    }

    //Set channel data to phase keys
    if (pole1Phase == "A") {
        parsedData["mVpA"] <- tempData["Channel0"];
        parsedData["mApA"] <- tempData["Channel1"];
        parsedData["mVpB"] <- tempData["Channel2"];
        parsedData["mApB"] <- tempData["Channel3"];
    } else if (pole1Phase == "B") {
        parsedData["mVpB"] <- tempData["Channel0"];
        parsedData["mApB"] <- tempData["Channel1"];
        parsedData["mVpA"] <- tempData["Channel2"];
        parsedData["mApA"] <- tempData["Channel3"];
    }

@if METER_PROTOCOL_REV == 2.06
    if (triggerEndTime != null) { // we have the trigger end time, need to calculate capture start/end times
        // server.log("We have the trigger time ("+type+")! "+triggerEndTime.toString()+" now let's calc the startTime and endTime...")

        local captureWindow = waveformCalculateCaptureWindow({
            "type"                  : type,
            "numSamples"            : parsedData.numSamples,
            "samplesAfterTrigger"   : parsedData.samplesAfterTrigger,
            "delta"                 : parsedData.deltaTime,
            "triggerEnd"            : triggerEndTime,
            "log"                   : false
        })

        parsedData.triggerStartTime <- triggerStartTime;
        parsedData.triggerEndTime   <- triggerEndTime;
        parsedData.startTime        <- captureWindow.start;
        parsedData.endTime          <- captureWindow.end;
    }

    if (endTime != null) { // we have the end time, need to calculate trigger window and capture begin time
        // server.log("We don't have the trigger time ("+type+")! So let's assume the endTime is when we got the message, and calculate the trigger time and start time!")

        local captureWindow = waveformCalculateCaptureWindow({
            "type"          : type,
            "numSamples"    : parsedData.numSamples,
            "delta"         : parsedData.deltaTime,
            "captureEnd"    : endTime,
            "log"           : false
        })

        local triggerWindow = waveformCalculateTriggerWindow({
            "type"                  : type,
            "delta"                 : parsedData.deltaTime,
            "samplesAfterTrigger"   : parsedData.samplesAfterTrigger,
            "duration"              : parsedData.duration,
            "triggerTypes"          : parsedData.triggerType,
            "captureEnd"            : endTime,
            "log"                   : false
        })

        parsedData["startTime"]         <- captureWindow.start;
        parsedData["endTime"]           <- captureWindow.end;
        parsedData["triggerStartTime"]  <- triggerWindow.start;
        parsedData["triggerEndTime"]    <- triggerWindow.end;
    }
@else

    local captureWindow = waveformCalculateCaptureWindow({
        "type"          : type,
        "numSamples"    : parsedData.numSamples,
        "delta"         : parsedData.deltaTime,
        "captureEnd"    : endTime,
        "log"           : false
    })

    local triggerWindow = waveformCalculateTriggerWindow({
        "type"                  : type,
        "delta"                 : parsedData.deltaTime,
        "samplesAfterTrigger"   : parsedData.samplesAfterTrigger,
        "duration"              : parsedData.duration,
        "triggerTypes"          : parsedData.triggerType,
        "captureEnd"            : endTime,
        "log"                   : false
    })

    parsedData["startTime"]         <- captureWindow.start;
    parsedData["endTime"]           <- captureWindow.end;
    parsedData["triggerStartTime"]  <- triggerWindow.start;
    parsedData["triggerEndTime"]    <- triggerWindow.end;
@end

    return parsedData;
}

function sendWaveformDataToFirebase(data, ts, reply=null) {
    local update = {};
@if METER_PROTOCOL_REV == 2.06
    local guid;
    local parseOptions = { "type": data.type, "data": data.data };

    if (g_WaveformExpectingType == data.type && g_WaveformTriggerStartTime != null) {
        parseOptions.triggerStartTime   <- uint64(g_WaveformTriggerStartTime);
        parseOptions.triggerEndTime     <- uint64(g_WaveformTriggerEndTime);
    } else {
        parseOptions.endTime <- uint64(ts+"000");
    }

@else
    local guid = FirebasePushID.generate();
    local parseOptions = { "type": data.type, "data": data.data, "endTime": uint64(ts+"000") };
@end
    local parsedData = parseWaveformData(parseOptions);

@if METER_PROTOCOL_REV == 2.06
    if (g_WaveformExpectingType == data.type && g_WaveformPushID != null) { //we found our match! Set our guid and clear the other crap
        guid = g_WaveformPushID;
        g_WaveformPushID = null;
        g_WaveformExpectingType = null;
        g_WaveformTriggerEndTime = null;
        g_WaveformTriggerStartTime = null;
    } else {
        guid = FirebasePushID.generate();
        g_WaveformExpectingType = (data.type == "waveform" ? "highRate" : "waveform");
        g_WaveformPushID = guid;
        g_WaveformTriggerStartTime = parsedData.triggerStartTime;
        g_WaveformTriggerEndTime = parsedData.triggerEndTime;
        g_WaveformTimer = imp.wakeup(10, function(){ //set a timer so that if we don't receive what we expect in a reasonable amount of time, clear our globals (so we don't pair some future fastRMS/waveform event with the wrong event)
            g_WaveformExpectingType = null;
            g_WaveformPushID = null;
            g_WaveformTriggerStartTime = null;
            g_WaveformTriggerEndTime = null;
        })
    }
@end

    parsedData["idAgent"] <- g_idAgent;

@if METER_PROTOCOL_REV == 2.06
    if (data.type == "highRate") {
        update["/v1/meterFastRMS/"+guid] <- parsedData;
        update["/v1/meter/"+g_idAgent+"/fastRMS/"+guid] <- true;
    } else {
        update["/v1/meterWaveforms/"+guid] <- parsedData;
        update["/v1/meter/"+g_idAgent+"/waveforms/"+guid] <- true;
    }
@else
    update["/v1/meterWaveforms/"+guid] <- parsedData;
    update["/v1/meter/"+g_idAgent+"/waveforms/"+guid] <- true;
@end

    g_FbRef.update("/", update)
    .then(function(data){
        if (reply) reply(true);
    })
    .fail(onFirebaseFailureFactory("sendWaveformDataToFirebase", null, reply))
}

g_MM.on("waveform", function(message, reply){
  sendWaveformDataToFirebase(message.data, message.ts, reply)
});

@include once "lib/Device/Generated/Device.dynamicData.device.nut"
@include once "lib/ETN_Breaker/Generated/ETN_Breaker.dynamicData.device.nut"
@include once "lib/Button/Generated/Button.dynamicData.device.nut"
@include once "src/DynamicData.agent.nut"

//NOTE: This handles the initial push of all SPIFlash data from DataManager class
g_MM.on("DATAMANAGER_SPIFLASH_DATA", function(message, reply){
  foreach (classType, categories in message.data) {
    foreach (category, data in message.data[classType]) {
      g_FbPusher.setDataWithTimestamp(classType, data, category);
    }
  }

  if ("breaker" in message.data && "staticData" in message.data.breaker && "numPoles" in message.data.breaker.staticData) {
      server.log("Writing # poles to Agent storage: "+message.data.breaker.staticData.numPoles)
      g_db.write(NUM_POLES, message.data.breaker.staticData.numPoles)
  }

  reply(true);
});

g_MM.on("ALL_INTERVALS", function(message, reply){
  foreach (type, interval in message.data) g_FbPusher.setData(type, {"val": interval, "ts": time()}, "interval");
})

// TODO: Does this need to change for EV-EMCB?
g_MM.on("ALL_DR_EVENT_STATUS", updateAllDREventStatus);

g_MM.on("UPDATE_POLE_1_PHASE", function(message, reply){
  local pole1Phase = message.data;
  g_EnergyBuckets.updatePole1Phase(pole1Phase);
  g_IntervalDataManager.updatePole1Phase(pole1Phase);
  g_db.write(POLE_1_PHASE, pole1Phase);
})

device.onconnect(function() {
  server.log("Device connected to agent");
  writeDynamicDataToFirebase("devices", true, "isConnected")
	.fail(function(data){
		server.error("Failed setting Device isConnected to true");
	})
});

device.ondisconnect(function() {
  server.log("Device disconnected from agent");
  writeDynamicDataToFirebase("devices", false, "isConnected")
	.fail(function(data){
		server.error("Failed setting Device isConnected to false");
	})
});

lastFirebaseDeviceConnectedState <- null;
devicePingFailTimer <- imp.wakeup(0, function(){});

function checkDeviceConnectedState(){

  device.on("online", function(data){
    //We're online!
    imp.cancelwakeup(devicePingFailTimer);
    if (lastFirebaseDeviceConnectedState != true) {
      writeDynamicDataToFirebase("devices", true, "isConnected")
      .then(function(ignore){
        lastFirebaseDeviceConnectedState = true;
      })
    }
    imp.wakeup(10, checkDeviceConnectedState);
  });

  imp.cancelwakeup(devicePingFailTimer);
  devicePingFailTimer = imp.wakeup(20.0, function(){ //if we do not hear back from device in 20 seconds, then consider the device offline
    if (lastFirebaseDeviceConnectedState != false) {
      writeDynamicDataToFirebase("devices", false, "isConnected")
      .then(function(ignore){
        lastFirebaseDeviceConnectedState = false;
      })
    }
    imp.wakeup(10, checkDeviceConnectedState);
  })

  device.send("ping", null);
}

lastFirebaseDeviceConnectedState <- null;
checkDeviceConnectedState();

function writeBreakerStaticDataToFirebase(data) {
  local fbUpdate = {};
  local ts = time();

  if ("lineTerminalStyle" in data) fbUpdate["/v1/breaker/" + g_idDevice + "/staticData/lineTerminalStyle"] <- {"val": data.lineTerminalStyle, "ts": ts};
  if ("ratedCurrent" in data) fbUpdate["/v1/breaker/" + g_idDevice + "/staticData/ratedCurrent"] <- {"val": data.ratedCurrent, "ts": ts};
  if ("ratedVoltage" in data) fbUpdate["/v1/breaker/" + g_idDevice + "/staticData/ratedVoltage"] <- {"val": data.ratedVoltage, "ts": ts};

  g_FbRef.update("/", fbUpdate)
  .fail(function(err){
    server.error("Failed to update breaker static data in Firebase, retrying in 10 seconds");
    imp.wakeup(10.0, function(){
      writeBreakerStaticDataToFirebase(data);
    });
  })
}

function readBreakerStaticDataFromFirebase() {
  local path = "/v1/breaker/" + g_idDevice + "/set/staticData";
  g_FbRef.read(path)
  .then(function(data){
    if (data != null) {
      g_MM.send("rpc", ["g_DataManager.updateData", ["breaker", "staticData", data]], null, null, {
        "onAck": function(message){ writeBreakerStaticDataToFirebase(data); }
      })
    }
  })
  .fail(function(err){
    // server.error("Failed to read \"breaker/set\" on Firebase: "+path)
    // printObject(err);
    imp.wakeup(10, readBreakerStaticDataFromFirebase);
  })
}

//Things we want to happen when the device boots
device.on("boot", function(data){
  device.send("bootack", null);
  readBreakerStaticDataFromFirebase();
})

// =============================================================================
// ROCKY_ROUTES ----------------------------------------------------------------
// ============================================================================{

function checkRPCResponseForErrors(data) {
  local retVal = {"success": true, "error": null};
  local replyData;

  //Check for RPC Promise fail errors
  if (typeof data == TYPE_TABLE && "Error" in data) {
    retVal.success = false;
    local errorData = (typeof data.Error == TYPE_ARRAY ? data.Error[0] : data.Error); //This is all silly gymnastics for how RPC wraps data
    if ("err" in errorData) errorData = errorData.err;
    retVal.error = errorData;
  } else {
    replyData = (typeof data == TYPE_ARRAY ? data[0] : data);
    if ("success" in replyData && replyData.success == false) {
      retVal.success = false;
      retVal.error = replyData.err;
    }
  }

  return retVal;
}

// This is a table format of g_EVSE_ERRORS
// It is keyed based on error code, which makes it easier to access
// This is auto-generated in generate-code:evse-errors-table

@include once "lib/ETN_EVSE/Generated/ETN_EVSE.errorsTable.nut"

@include once "lib/ETN_EVSE/Generated/ETN_EVSE.errors.nut"

g_EVSE_EVENTS <- [ { //TODO: This should be auto-generated
  "data" : {
    "oldValue" : "Old value of static data",
    "value" : "New value of static data"
  },
  "description" : "EVSE Static Data Changed",
  "target" : "Static data identifier"
}, {
  "description" : "EVSE Reset"
}, {
  "description" : "EVSE Failure"
}, {
  "description" : "EVSE J1772 State Change"
}, {
  "description" : "EVSE Started Charging"
}, {
  "description" : "EVSE Stopped Charging"
}, {
  "description" : "EVSE Plugged In"
}, {
  "description" : "EVSE Unplugged"
}, {
  "description" : "EVSE Enabled"
}, {
  "description" : "EVSE Disabled"
}, {
  "description" : "EVSE Configuration Changed"
}, {
  "description" : "EVSE Fault",
  "subEventEnumerations" : "/v1/enumerations/evse/faultReasons"
} ];

g_MM.on("logErrorsHumanReadable", function(message, reply) {
    local data = message.data;


    for(local i=0; i<data.numErrors; i++){
        local errorArray = data.errors[i]

        swap8(errorArray[5]).swap2();   //Yay Endianness!
        data.errors[i] = {
            "errorCode": errorArray[0],
            "rawErrorData": [
                errorArray[1],
                errorArray[2],
                errorArray[3],
                errorArray[4],
            ],
            "errorTime": uint64(errorArray[5]).toString()
           // "possibleErrors": []
        }
        server.log(JSONEncoder.encode(data))

        // for(local j=0; j<g_EVSE_ERRORS.len(); j++){
        //     if(g_EVSE_ERRORS[j].code == data.errors[i].errorCode){
        //         data.errors[i].possibleErrors.push(g_EVSE_ERRORS[j])
        //     }
        // }
    }

    delete data.errors
    server.log(JSONEncoder.encode(data))
})

//TODO: This needs to be wrapped into the API documentation and generated
g_Rocky.get(@"/v1/evse/getErrors", function(context){
    local data = [
        "g_EVSE.readErrors",
        [true]
    ]

    g_MM.send("rpc", data, null, null, {
      "onReply": function(message, data) {
        local data = data[0];

        for(local i=0; i<data.numErrors; i++){
            local errorArray = data.errors[i]

            swap8(errorArray[5]).swap2();   //Yay Endianness!
            data.errors[i] = {
                "errorCode": errorArray[0],
                "rawErrorData": [
                    errorArray[1],
                    errorArray[2],
                    errorArray[3],
                    errorArray[4],
                ],
                "errorTime": uint64(errorArray[5]).toString()
                "possibleErrors": []
            }

            for(local j=0; j<g_EVSE_ERRORS.len(); j++){
                if(g_EVSE_ERRORS[j].code == data.errors[i].errorCode){
                    data.errors[i].possibleErrors.push(g_EVSE_ERRORS[j])
                }
            }
        }
        context.send(200, data);
      },
      "onFail": function(message, err, retry) {
        context.send(200, {"err": err, "message": message})
      }
    })
})

//TODO: This needs to be wrapped into the API documentation and generated
/*g_Rocky.get(@"/v1/evse/reset", function(context) {
    local data = [
        "g_EVSE.resetEEPROM",
        []
    ]

    g_MM.send("rpc", data", null, null, {
      "onReply": function(message, data) {
        local data = data[0];
        context.send(200, data);
      },
      "onFail": function(message, err, retry) {
        context.send(200, {"err": err, "message": message})
      }
    })
})*/


@include once "lib/ETN_EVSE/Generated/ETN_EVSE.addresses.device.nut"
@include once "lib/ETN_EVSE/Generated/ETN_EVSE.addresses.agent.nut"
@include once "lib/ETN_EVSE/Generated/ETN_EVSE.enumerations.nut"
@include once "lib/ETN_EVSE/Generated/ETN_EVSE.map.agent.nut"

silentRegisters <- {
    [ETN_EVSE_MBREG_LAST_READ_CURRENT_IDX] = true,
    [ETN_EVSE_MBREG_LAST_READ_VOLTAGE_IDX] = true,
    [ETN_EVSE_MBREG_TIME_IDX] = true,
    [ETN_EVSE_MBREG_DISPLAY_LINE_4_IDX] = true,
}

tolerenceRegisters <- {
    [ETN_EVSE_MBREG_PILOT_VOLTAGE_ADC_IDX] = [25, -99999], //First value is tolerence, second value is last value
    [ETN_EVSE_MBREG_ENERGY_TOTAL_CHARGE_IDX] = [1000, -99999],
    [ETN_EVSE_MBREG_ENERGY_TOTAL_FOREVER_IDX] = [1000, -99999],
    [ETN_EVSE_MBREG_ENERGY_TOTAL_PLUG_IDX] = [1000, -99999],
    [ETN_EVSE_MBREG_ENERGY_TOTAL_SINCE_RESET_IDX] = [1000, -99999],
}

function handleRegisterChanged(address, value){
  local rawValue = value;

  local logStr = format("%35s [0x%.4X] = ", g_REGISTER_MAP[address][MB_REGISTER_DEFINE].slice(15), address)

  if(g_REGISTER_MAP[address][MB_REGISTER_DATA_TYPE] == "DOUBLE"){
      //value = BigFromDoubleBlob(swap8(value)).toString()
      swap8(value)
      value.seek(0)
      value = value.readn(DOUBLE) //This is a lossy operation in terms of precision, but it sure is easy and fast!
      rawValue = value;
  }

  if(g_REGISTER_MAP[address][MB_REGISTER_DATA_TYPE] == "UINT64"){
      swap8(value).swap2();   //Yay Endianness!
      value = uint64(value)
      rawValue = value;
      logStr += format("%s = %s", value.toString(), value.tostring())
  }
  else if(g_REGISTER_MAP[address][MB_REGISTER_BIT_ENUMERATION]) {
      local setBits = []

      foreach(key, val in g_REGISTER_MAP[address][MB_REGISTER_BIT_ENUMERATION]){
          if(bitRead(value, key.tointeger())){
              //setBits.push( format("%s (%s)", val[0], val[1]) )
              setBits.push(val)
          }
      }

      logStr += format("%s = 0x%.4X = %s", value.tostring(), value, http.jsonencode(setBits))
      value = http.jsonencode(setBits)
      rawValue = value;
  }
  else if(g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION] && value.tostring() in g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION]){
      logStr +=format("%s = 0x%.4X = %s (%s)", value.tostring(), value, g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION][value.tostring()][0].slice(14), g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION][value.tostring()][1]) //Code define, description
      value = [ value, g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION][value.tostring()][0], g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION][value.tostring()][1] ]
  }
  else if(typeof(value) == TYPE_ARRAY) {
      logStr += arrayToString(value)
  }
  else if(typeof(value) == TYPE_BLOB) {
      value = arrayToHexString(value)
      rawValue = value;
      logStr += value
  }
  else if(typeof(value) == TYPE_STRING) {
      logStr += value
  }
  else {
      logStr += format("%s = 0x%.4X", value.tostring(), value)
  }

  // Mute regsiters that are tolerenced, unless the tolerence is exceeded
  if(address in tolerenceRegisters){
      // if(math.abs(tolerenceRegisters[address][1]-value) > tolerenceRegisters[address][0]){    //TODO: BUG:	ERROR: arith op - on between 'integer' and 'instance' - Need to implement metamethods or check to see if we are a native type or an instance and check using the methods...
      //     if(address in silentRegisters)
      //         delete silentRegisters[address]
      //     tolerenceRegisters[address][1] = value
      // } else {
          silentRegisters[address] <- true
      //}
  }


  if( !(address in silentRegisters)) {
      server.log(logStr)
  }

  if(address == ETN_EVSE_MBREG_TEMPORARY_ERROR_IDX) {
    handleTemporaryError(rawValue);
  } else if(address == ETN_EVSE_MBREG_ERROR_COUNT_IDX) {
    if(rawValue > 0){
      handleErrors();
    }
  } else if(address == ETN_EVSE_MBREG_EVENT_COUNT_IDX) {
    if(rawValue > 0){
      handleEvents();
    }
  }

  // Update generic modbus tree primarily for debugging
  // g_FbPusher.updateData("v1/evse/" + g_idAgent +"/modbus/" + g_REGISTER_MAP[address][MB_REGISTER_DEFINE].slice(15), value)

  // If register contains FB location, push to it
  if(g_REGISTER_MAP[address][MB_REGISTER_FB_LOCATION] != null){
    local location      = g_REGISTER_MAP[address][MB_REGISTER_FB_LOCATION];
    local arr           = split(location, "/");
    local category      = arr[0]; //"dyanmicData", "configuration", etc...
    local parameter     = arr[1]; //"state", etc...
    local tsCategories  = ["dynamicData", "configuration", "staticData"]; //Paths that require {"val": value, "ts": ts}
    local fbValue;

    if(g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION] != null && g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION][rawValue.tostring()].len() >= 3){
      fbValue = g_REGISTER_MAP[address][MB_REGISTER_ENUMERATION][rawValue.tostring()][2];
    } else {
      fbValue = rawValue;
    }

    if(g_REGISTER_MAP[address][MB_REGISTER_FB_DATATYPE] != null){
      switch(g_REGISTER_MAP[address][MB_REGISTER_FB_DATATYPE].toupper()){
        case "BOOLEAN":
          if(typeof fbValue == "string"){
            if(fbValue.tolower() == "true") fbValue = true;
            else if(fbValue.tolower() == "false") fbValue = false;
            else server.log("Invalid FB value: "+fbValue+" (expected BOOLEAN).");
          } else if(typeof fbValue == "integer") {
            if(fbValue == 0) fbValue = false;
            else fbValue = true;
          } else if(typeof fbValue == "bool"){
            // do nothing
          } else {
            server.log("WARNING: Unknown fbValue type: "+(typeof fbValue));
          }
          break;
        case "STRING":
          if(typeof fbValue != "string"){
            fbValue = fbValue.tostring();
          }
          break;
        case "NUMBER":
        default:
          // do nothing
      }
    }

    if (tsCategories.find(category) != null) {
        g_FbPusher.setDataWithTimestamp("evse", fbValue, category, parameter)
    } else {
        g_FbPusher.setData("evse", fbValue, category, parameter);
    }
  }
}

g_EVSEPlugSessions <- EVSEPlugSessions.init({
    "db": g_db,
    "fb": g_FbRef,
    "mm": g_MM,
})

// Uncomment for VTI regression testing
/*g_MM.on("agentRestart", function(message, reply) {
    server.log("Restarting agent; hopefully you saved everything properly!!! >:}");
    // Restart the agent
    server.restart();
});*/

g_MM.on("onRegisterChanged", function(message, reply){
    local address = message.data[0];
    local value = message.data[1];

    handleRegisterChanged(address,value);
});

g_MM.on("onMultiRegisterChanged", function(message, reply){
  local arr = message.data;
  local len = message.data.len();
  for (local i=0; i<len; i++) {
    local address = arr[i][0];
    local value = arr[i][1];

    handleRegisterChanged(address, value);
  }
});

g_MM.on("EV_MICRO_FAILURE", function(message, reply) {
    local guid = FirebasePushID.generate();
    local payload = {};

    if (message.data.microStatus == false) {
        payload.type <- "EV_MICRO_FAILURE";
        payload.data <- {"breakerStatus": message.data.breakerStatus}
        payload.description <- "EV microprocessor failure and breaker is "+(message.data.breakerStatus == true ? "closed" : "open");
        payload.timestamp <- time();
        payload.idAgent <- g_idAgent;

        g_FbRef.write("/v1/agentExceptions/"+g_idAgent+"/"+guid, payload)
        .then(function(data){
            reply({"success": true})
        })
        .fail(function(err){
            server.log("Setting agentException in Firebase failed:")
            printObject(err);
            reply({"success": false})
        })
    }
})

//TODO: What am I supposed to do?
function handleTemporaryError(value){
  server.log("handleTemporaryError not implemented!")
}

function handleEvents(){
  local data = [
    "g_EVSE.readEvents",
    [true]
  ]

  g_MM.send("rpc", data, null, null, {
    "onReply": function(message, data) {
      local data = data[0];
      if(typeof data.time == "blob"){
          // Convert to uint64 with correct endianess
          swap8(data.time).swap2();
          data.time = uint64(data.time);
      }
      local guid = FirebasePushID.generate();
      local fbLocation = "v1/evse/"+g_idAgent+"/events/"+guid;
      local fbData = {
        idEventType = data.code,
        time = (data.time ? data.time : time())
      };
      g_FbRef.write(fbLocation,fbData,function(error,data){
        if(error){
          server.log("Error updating events data: "+error);
          server.log("  Trying to update location: "+fbLocation);
          server.log("  Trying to update data: "+http.jsonencode(fbData));
        }
      });
    },
    "onFail": function(message, err, retry) {
      server.log("Error trying to read EVSE EVENT registers: "+err);
    }
  })
}

function handleErrors(){
  local data = [
      "g_EVSE.readErrors",
      [true]
  ]

  g_MM.send("rpc", data, null, null, {
    "onReply": function(message, data) {
      local data = data[0];
      local faultReason = "Unknown";
      local faults = [];

      for(local i=0; i<data.numErrors; i++){
          local errorArray = data.errors[i]

          swap8(errorArray[5]).swap2();   //Yay Endianness!
          data.errors[i] = {
              "errorCode": errorArray[0],
              "rawErrorData": [
                  errorArray[1],
                  errorArray[2],
                  errorArray[3],
                  errorArray[4],
              ],
              "errorTime": uint64(errorArray[5]).toString()
              "possibleErrors": []
          }

          /*for(local j=0; j<g_EVSE_ERRORS.len(); j++){
              if(g_EVSE_ERRORS[j].code == data.errors[i].errorCode){
                  data.errors[i].possibleErrors.push(g_EVSE_ERRORS[j])
                  faultReason = g_EVSE_ERRORS[j].description;
              }
          }*/
          faults.push(g_EVSE_ERRORS_TABLE[data.errors[i].errorCode.tostring()].description);

      }
      if(faults.len() > 0){
        if(faults.len() == 1){
          faultReason = faults[0];
        } else {
          faultReason = "";
          for(local i=0; i<faults.len(); i++){
            faultReason += (i+1)+". "+faults[i]+". ";
          }
        }
      }
      g_FbRef.update("v1/evse/"+g_idAgent+"/dynamicData/faultReason",{"val": faultReason, "ts": time()});
      /*context.send(200, data);*/
    },
    "onFail": function(message, err, retry) {
      server.log("Error trying to read EVSE ERROR registers: "+err);
        /*context.send(200, {"err": err, "message": message})*/
    }
  })
}

function parseRPCReply(reply) {
  local data = {"success": true, "error": null};

  //Check for RPC Promise fail errors
  if (typeof reply == TYPE_TABLE && "Error" in reply) {
    data.success = false;
    local errorData = (typeof reply.Error == TYPE_ARRAY ? reply.Error[0] : reply.Error); //This is all silly gymnastics for how RPC wraps data
    if ("err" in errorData) errorData = errorData.err;
    data.error = errorData;
    return data;
  }

  local replyData = (typeof reply == TYPE_ARRAY ? reply[0] : reply);
  if ("success" in replyData && replyData.success == false) {
    data.success = false;
    data.error = replyData.err;
    return data;
  }

  return data;
}

// ROCKY ROUTES TO INCLUDE:
@include once "src/Rocky/generated/routeAccelerometer.agent.nut"
@include once "src/Rocky/generated/routeBreaker.agent.nut"
@include once "src/Rocky/generated/routeButton.agent.nut"
@include once "src/Rocky/generated/routeCommissioning.agent.nut"
@include once "src/Rocky/generated/routeDevice.agent.nut"
@include once "src/Rocky/generated/routeEVSE.agent.nut"
@include once "src/Rocky/generated/routeLED.agent.nut"
@include once "src/Rocky/generated/routeMeter.agent.nut"
@include once "src/Rocky/generated/routeRPC.agent.nut"
@include once "src/Rocky/generated/routeThermometer.agent.nut"

// FIREBASE API HANDLER:

//TODO: Is this old leftover test code from something?
g_GFValues <- {
    "name" : "gfData",
    "x" : [],
    "y" : []
}

device.on("GFCT_DATA", function(data){
  local d = data[0]
  local data = data[1]
  local samples = {
    "x": []
    "y": []
  }

  local bigVal = false

  local lastD = date(time() - 10)
  lastD.usec = -999
  try{

    data.seek(0)
    while(!data.eos()){
      samples.y.push(data.readn('i'))   //data is coming in micro-amps.  A value over 17000 (for a while) means we will trip
      samples.x.push(format("%04i-%02i-%02i %02i:%02i:%02i.%06i",
      d.year, d.month + 1, d.day,
      d.hour, d.min, d.sec, d.usec))

      // if(d.usec < lastD.usec || d.time < lastD.time){
      //     server.log("RAN BACKWARDS")
      //     server.log(format("%04i-%02i-%02i %02i:%02i:%02i.%06i",
      //     d.year, d.month + 1, d.day,
      //     d.hour, d.min, d.sec, d.usec) + http.jsonencode(d))

      //     server.log(format("%04i-%02i-%02i %02i:%02i:%02i.%06i",
      //     lastD.year, lastD.month + 1, lastD.day,
      //     lastD.hour, lastD.min, lastD.sec, lastD.usec) + http.jsonencode(lastD))

      //     server.log(lastD.usec + 1000)
      // }
      // lastD = d

      //All data should be ~1 ms apart
      d.usec += 100   //We were getting some data overlap on Plottly so we are going to contract things just a a bit...
      if(d.usec >= 1000000){
        d.time++
        local usec = d.usec - 1000000
        d = date(d.time)
        d.usec = usec
      }

      lastD = d
    }

    for(local i =0; i< samples.y.len(); i++){
      g_GFValues.y.push(samples.y[i])
      g_GFValues.x.push(samples.x[i])
      if(samples.y[i] > 10000 && (bigVal == false || samples.y[i] > bigVal.y))
      bigVal = {
        "y": samples.y[i]
        "x": samples.x[i]
      }
    }

    if(bigVal != false){
      server.error("BIG VALUE DETECTED!!!! - " + JSONEncoder.encode(bigVal))
    }

  } catch(ex){
    //g_GFValues[millis.tostring()] <- data
    server.log(ex)
  }

})

//TODO: This needs to be wrapped into the API documentation and generated
g_Rocky.get("/v1/evse/gfData", function(context){
  context.send(200, JSONEncoder.encode(g_GFValues))
  g_GFValues = {
    "name" : "gfData",
    "x" : [],
    "y" : []
  }
})

// =============================================================================
// ------------------------------------------------------------ END_ROCKY_ROUTES
// ============================================================================}

g_FbRef.on("/", function(path, change){    //This is the path relative to what is called with firebase.stream
    local fbRequests = fromCache();
    local res;  // Give access to the object to the catch in case we have an error
    //server.log("STREAM - " + JSONEncoder.encode(fbRequests))

    if(typeof(fbRequests) == TYPE_TABLE && fbRequests.len() > 0){
        try {
            local keys = sortedKeys(fbRequests)

            // We could loop through each request, in order received
            // but we would actually prefer to only deal with the most current request
            // otherwise we get into weird undefined race conditions when our connection to
            // Firebase goes down
            //TODO: BUG: We need to test what happens when firebase goes down and then we reconnect - we probably need to be adjusting our startAt header somehow...

            local pushID;
            local fbReq = null;

            for (local i = keys.len()-1; i >= 0; i--) {
              pushID = keys[i];
              if (fbRequests[pushID] != null) {
                fbReq = fbRequests[pushID];
                break;
              }
            }

            if (fbReq == null) {
              server.error("All push IDs in Firebase internal request cache are null");
              printObject(fbRequests);
              return;
            }


            res = fbHTTPResponse(pushID, fbReq)

            g_FbRef.remove("v1/api/"+ g_idAgent +"/request/" + pushID)

            local req = {
                body = null,
                headers = ("headers" in fbReq ? fbReq.headers : {}),
                method = fbReq.method,
                path = fbReq.path,
                query = {}
            };

            local lowHeaders = tableToLower(req.headers)

            if("body" in fbReq){
                if ("content-type" in lowHeaders && lowHeaders["content-type"].tolower().find("application/json") != null && typeof(fbReq.body) == "table") { //We accept either JSON Strings from Firebase or actual JSON Tables
                    req.body <- JSONEncoder.encode(fbReq.body);
                } else {
                    req.body <- fbReq.body;
                }
            }

            //TODO: BUG: Need to delete the Request tree from firebase once we receive it so we don't accidentally refire the same command if there are issues with the Firebase Stream

            server.log("------------------------------")
            server.log("Received data from Firebase")
            server.log("path    = " + req.path)
            server.log("method  = " + req.method)
            server.log("headers = " + JSONEncoder.encode(req.headers))
            server.log("body    = " + JSONEncoder.encode(req.body))

            g_Rocky._onrequest(req, res); //This routes the request into Rocky.  Our fbHTTPResponse impersonator object will route res.send back into firebase

        } catch(exception){
            server.error("Firebase API Request Handler caused Exception: " + exception)
            res.send(500, "FB API Request Exception: " + exception + "\nPlease Contact Eaton GMBD");
            return;
        }
    }
})

//Open stream for API business!
g_FbRef.stream("v1/api/"+ g_idAgent +"/request", {"orderBy": "$key", "startAt": FirebasePushID.startAtStringForTimestamp(date()), "limitToLast": 1}, null, null, checkAndConvertHeaders);

// =============================================================================
// --------------------------------------------------- END_MAIN_APPLICATION_CODE
// ============================================================================}

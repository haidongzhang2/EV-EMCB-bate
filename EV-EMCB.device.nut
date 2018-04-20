// ============================================================================{
// Copyright (c) Eaton
// EATON CONFIDENTIAL
/*
$$$$$$$$$$$$$$$$$$.         .$$$$$$$$$$$$$$$$:.           :Z$$$$$$$$$=. .Z$$$$$+
$$$$$$$$$$$$$$$$$Z.      .  .$$$$$$$$$$$$$ZI..            :Z$$$$$$$$$Z. .Z$$$$$+
$$$$$$$$$$$$$$Z$$..    ..Z  .$Z$$$$$$$$$$$..              :Z$$$$$$$$$$:..Z$$$$$+
$$$$$$$..........      ..$..       Z$$$$$:       ......   :Z$$$$$$$$$ZZ..Z$$$$$+
$$$$$$$$$$$$$$$$.      .Z$?.      .Z$$$ZZ.     . ~$$$ZZ.. :Z$$$$$$$$$$$:.$$$$$$?
$$$$$$$$$$$$$$$Z.      .$$Z.      .Z$$$Z7.     .+$$$$$$$..:Z$$$$$:$$$$$$.$$$$$$+
$$$$$$$$$$$$$$$.      .           .Z$$$Z:.     .$$$$$$$$..:Z$$$$$.ZZ$$$Z~$$$$$$+
$$$$$$$$$$$$$$$                    Z$$$Z?.     .Z$$$$$$$. :Z$$$$$.,Z$$$$$$$$$$$+
$$$$$$$........      .........    .Z$$$$$.     ..7$ZZ$Z.. :Z$$$$$..Z$$$$$$$$$$$+
$$$$$$$$$$$$ZI.     ..$ZZZ$$Z.    .Z$$$$$=.      ......   :Z$$$$$..,Z$$$$$$$$$$+
$$$$$$$$$$$$$.      .Z$$$$$$Z:.   .Z$$$$$Z,.              :Z$$$$$. .$$$$$$$$$$$+
$$$$$$$$$$$$I.      .$$$$$$$$$.   .Z$$$$$$$?..            :Z$$$$$.  :$$$$$$$$$$+
777777777777..     .7777777777,   .$777777777.           .,I77777.  .7777777777=
*/

// Copyright (c) Electric Imp
// Portions of this file are licensed under the MIT License
// http://opensource.org/licenses/MIT


// Replace importOnce (metascript) with #include (preprocessor)
// //\? importOnce\("([A-Za-z0-9./_]+)"\)

// ============================================================================}
@include once "src/EMCBConstants.nut"
@include once "src/EMCBConstants.device.nut"
@include once "src/EMCBSPIFlashConstants.device.nut"
@include once "lib/LibraryConstants.device.nut"
@include once "lib/ETN_StandardLib/ETN_StandardLib.class.device.nut"
@include once "lib/ConnectionManager/ConnectionManager.singleton.nut"
@include once "lib/Promise/Promise.class.nut"
@include once "lib/MessageManager/MessageManager.class.nut"
@include once "lib/MessageManager/MessageManagerExtended.class.nut"
@include once "lib/RPC/RPC.class.nut"
@include once "lib/Button/Button.singleton.nut"
@include once "lib/SentecMeter/SentecMeter.singleton.nut"
@include once "lib/ETN_EVSE/ETN_EVSE.singleton.nut"
@include once "lib/DataManager/DataManager.device.singleton.nut"
@include once "lib/Device/Device.device.singleton.nut"
@include once "lib/SpiFlashLogger/SpiFlashLogger.class.nut"
@include once "lib/SPIFlashSafeFile/SPIFlashSafeFile.class.nut"
@include once "lib/ETN_Breaker/ETN_Breaker.singleton.nut"
@include once "lib/SX150x/SX1509.singleton.nut"
@include once "lib/SX150x/ExpGPIO.class.nut"
@include once "lib/Bargraph/Bargraph.singleton.nut"
@include once "lib/TMP1x2/TMP1x2.singleton.nut"
@include once "lib/LIS3DH/LIS3DH.singleton.nut"
@include once "lib/DemandResponse/DemandResponse.singleton.device.nut"
// @include once "lib/ImpWrapper/ImpWakeupRetry.class.nut";

// =============================================================================
// IMP_WRAPPER -----------------------------------------------------------------
// ============================================================================{
// =============================================================================

//Override imp with a class that wraps imp.wakeup with a retry if it fails
// imp <- ImpWakeupRetry();

// g_WakeupFailedCount <- 0;
// g_WakeupFailedMessage <- "";
// imp.onWakeupFail(function(duration){
//   g_WakeupFailedMessage = "Wakeup with duration "+duration+" failed";
//   g_WakeupFailedCount++;
// })

// =============================================================================
// END_IMP_WRAPPER -------------------------------------------------------------
// ============================================================================}

// =============================================================================
// CONNECTION_MANAGEMENT -------------------------------------------------------
// ============================================================================{
g_CM <- ConnectionManager.init({
    "blinkupBehavior" : ConnectionManager.BLINK_ALWAYS,
    "stayConnected" : true
});

g_CM.onDisconnect(function(expected) {
    if (expected) {
        // log a regular message that we disconnected as expected
        g_CM.log("Expected Disconnect at " + hardware.millis());
    } else {
        // log an error message that we unexpectedly disconnected
        g_CM.error("Unexpected Disconnect at " + hardware.millis());
    }
});

g_CM.onConnect(function() {
    // Send a message to the agent indicating that we're online
    DataManager.dynamicData(DEVICE_IS_CONNECTED, [true]);  //NOTE: This should be taken care of on the Agent with device.onconnect but put here just for the sake of we've seen the Agent side of things not work...
    g_CM.log(time() + " - Reconnected at " + hardware.millis())
});

// Set the recommended buffer size
imp.setsendbuffersize(16384);

//NOTE: Check to see if the button is held down on power up. If so, this is our
//      "cheat code" for when blinkUp is not working in the field, so the device
//      will attempt to connect to the stored default SSID/pass so that we
//      at least have the ability to debug OTA.
PIN_DI_BUTTON_IDENTIFY.configure(DIGITAL_IN_PULLUP)
if (hardware.wakereason() == WAKEREASON_HW_RESET && imp.getssid() == "" && PIN_DI_BUTTON_IDENTIFY.read() == 0) {
  imp.setwificonfiguration(DEFAULT_SSID, DEFAULT_PASSPHRASE);
  server.disconnect();
  server.connect();
}
// =============================================================================
// END_CONNECTION_MANAGEMENT ---------------------------------------------------
// ============================================================================}

// =============================================================================
// SPIFLASH_CONFIGURATION ------------------------------------------------------
// ============================================================================{
const STATIC_DATA = "staticData"
const CONFIGURATION = "configuration"
const STATISTICS = "statistics"
const ERRORS = "errors"
const EVENTS = "events"
const INTERVAL_ENERGY = "intervalEnergy"

//hardware.spiflash.setspeed(18000000)  //TODO: BUG: THere were some issues with this in impOS 34 and it isn't properly tested on impOS 36 in the EMCB and can brick the deivce so we are removing for now.  //Maximum the imp-003 will support - It is essential that you carefully determine a safe speed before writing the SPI flash in software. If the speed is set too high, it may cause the imp to reboot on connection to the server or to damage the SPI flash chip during subsequent write operations. Determine a safe speed by trying various speeds and checking its effect on your device, ideally on a scope. Reading at too high a speed is safe, in that the worst that can happen is that the device’s imp will crash and restart; set a lower speed in your Squirrel code. However, writing at too high a speed is dangerous because it may cause the WiFi firmware to be overwritten, which will render the imp permanently inoperable.
//SPIFLASH.enable();
// function eraseSPIFLASH(restart=false){  //TODO: is this a security risk?  Should we destroy this function from production code?  Or is it too useful to have access to via RPC?
//   SPIFLASH.enable();
//   local size = SPIFLASH.size()/4096;
//   for (local i = 0; i < size; i++) {
//     SPIFLASH.erasesector(i*4096);
//   }
//   if (restart) {
//     server.restart();
//   }
//   SPIFLASH.disable();
// }
// eraseSPIFLASH();

// server.log(format("SPI Flash Chip ID = 0x%.8X, Size = %d bytes = %d KB", SPIFLASH.chipid(), SPIFLASH.size(), SPIFLASH.size()/1024));
// SPIFLASH.disable();

//NOTE: Do all SPIFlashSafeFile instantiation and pass them into later class instantiations
//TODO: use constants, rename "configuration" to "config", "statistics" to "stats", and put all *SpiFlash things into a big object so that we don't have to have all these globals...

deviceSpiFlash <- {
    [STATIC_DATA]   = SPIFlashSafeFile(SFSF_STATIC_DATA_DEVICE_BOUNDARY_ADDR_START, SFSF_STATIC_DATA_DEVICE_BOUNDARY_ADDR_END),
    [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_DEVICE_BOUNDARY_ADDR_START, SFSF_CONFIG_DEVICE_BOUNDARY_ADDR_END),
    [STATISTICS]    = SPIFlashLogger(SFLOGGER_STATISTICS_DEVICE_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_DEVICE_BOUNDARY_ADDR_END),
    [ERRORS]        = SPIFlashLogger(SFLOGGER_ERRORS_BOUNDARY_ADDR_START, SFLOGGER_ERRORS_BOUNDARY_ADDR_END),
    [EVENTS]        = SPIFlashLogger(SFLOGGER_LOGGER_EVENTS_BOUNDARY_ADDR_START, SFLOGGER_LOGGER_EVENTS_BOUNDARY_ADDR_END)
};

//UNCOMMENT THIS TO SET CLASSES
// g_DeviceStaticData <- deviceSpiFlash.staticData.read({})
// if (!("classes" in g_DeviceStaticData)) g_DeviceStaticData.classes <- { "device": true, "meter": true, "thermometer": true, "accelerometer": true, "breaker": true, "button": true, "led": true };
// deviceSpiFlash.staticData.write(g_DeviceStaticData)

// connectionSpiFlash <- {
//     [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_CONNECTION_BOUNDARY_ADDR_START, SFSF_CONFIG_CONNECTION_BOUNDARY_ADDR_END),
//     [STATISTICS]    = SPIFlashLogger(SFLOGGER_STATISTICS_CONNECTION_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_CONNECTION_BOUNDARY_ADDR_END),
// }

breakerSpiFlash <- {
    [STATIC_DATA]   = SPIFlashSafeFile(SFSF_STATIC_DATA_ETN_BREAKER_BOUNDARY_ADDR_START, SFSF_STATIC_DATA_ETN_BREAKER_BOUNDARY_ADDR_END),
    [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_ETN_BREAKER_BOUNDARY_ADDR_START, SFSF_CONFIG_ETN_BREAKER_BOUNDARY_ADDR_END),
    [STATISTICS]    = SPIFlashLogger(SFLOGGER_STATISTICS_ETN_BREAKER_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_ETN_BREAKER_BOUNDARY_ADDR_END)
};

meterSpiFlash <- {
    [STATIC_DATA]     = SPIFlashSafeFile(SFSF_STATIC_DATA_METER_BOUNDARY_ADDR_START, SFSF_STATIC_DATA_METER_BOUNDARY_ADDR_END),
    [CONFIGURATION]   = SPIFlashSafeFile(SFSF_CONFIG_METER_BOUNDARY_ADDR_START, SFSF_CONFIG_METER_BOUNDARY_ADDR_END),
    [STATISTICS]      = SPIFlashLogger(SFLOGGER_STATISTICS_METER_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_METER_BOUNDARY_ADDR_END),
    [INTERVAL_ENERGY] = SPIFlashLogger(SFLOGGER_INTERVAL_ENERGY_DATA_BOUNDARY_ADDR_START, SFLOGGER_INTERVAL_ENERGY_DATA_BOUNDARY_ADDR_END)
};

evseSpiFlash <- {
    [STATIC_DATA] =    SPIFlashSafeFile(SFSF_STATIC_DATA_ETN_EVSE_BOUNDARY_ADDR_START, SFSF_STATIC_DATA_ETN_EVSE_BOUNDARY_ADDR_END),
    [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_ETN_EVSE_BOUNDARY_ADDR_START, SFSF_CONFIG_ETN_EVSE_BOUNDARY_ADDR_END),
    [STATISTICS] =    SPIFlashLogger(SFLOGGER_STATISTICS_ETN_EVSE_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_ETN_EVSE_BOUNDARY_ADDR_END)
}

demandResponseSpiFlash <- {
    [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_DEMAND_RESPONSE_BOUNDARY_ADDR_START, SFSF_CONFIG_DEMAND_RESPONSE_BOUNDARY_ADDR_END),
    [STATISTICS]    = SPIFlashLogger(SFLOGGER_STATISTICS_DEMAND_RESPONSE_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_DEMAND_RESPONSE_BOUNDARY_ADDR_END)
}

// dataPushSpiFlash <- {
//     [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_DATA_PUSH_BOUNDARY_ADDR_START, SFSF_CONFIG_DATA_PUSH_BOUNDARY_ADDR_END),
// }

bargraphSpiFlash <- {
    [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_BARGRAPH_BOUNDARY_ADDR_START, SFSF_CONFIG_BARGRAPH_BOUNDARY_ADDR_END),
}

// buttonSpiFlash <- {
//     [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_BUTTON_BOUNDARY_ADDR_START, SFSF_CONFIG_BUTTON_BOUNDARY_ADDR_END),
//     [STATISTICS]    = SPIFlashLogger(SFLOGGER_STATISTICS_BUTTON_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_BUTTON_BOUNDARY_ADDR_END)
// }

// buzzerSpiFlash <- {
//     [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_BUZZER_BOUNDARY_ADDR_START, SFSF_CONFIG_BUZZER_BOUNDARY_ADDR_END),
// }

// accelerometerSpiFlash <- {
//     [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_ACCEL_BOUNDARY_ADDR_START, SFSF_CONFIG_ACCEL_BOUNDARY_ADDR_END),
//     [STATISTICS]    = SPIFlashLogger(SFLOGGER_STATISTICS_ACCEL_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_ACCEL_BOUNDARY_ADDR_END)
// }

// tempsensorSpiFlash <- {
//     [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_TEMP_SENSOR_BOUNDARY_ADDR_START, SFSF_CONFIG_TEMP_SENSOR_BOUNDARY_ADDR_END),
//     [STATISTICS]    = SPIFlashLogger(SFLOGGER_STATISTICS_TEMP_SENSOR_BOUNDARY_ADDR_START, SFLOGGER_STATISTICS_TEMP_SENSOR_BOUNDARY_ADDR_END)
// }

// scheduleSpiFlash <- {
//     [CONFIGURATION] = SPIFlashSafeFile(SFSF_CONFIG_SCHEDULER_BOUNDARY_ADDR_START, SFSF_CONFIG_SCHEDULER_BOUNDARY_ADDR_END)
// }

// =============================================================================
// -------------------------------------------------- END_SPIFLASH_CONFIGURATION
// ============================================================================}


// =============================================================================
// MAIN_APPLICATION_CODE -------------------------------------------------------
// ============================================================================{

const BRKR_TYPE = "breaker";
const EVSE_TYPE = "evse";
const ACCEL_TYPE = "accelerometer";
const DEVICE_TYPE = "devices";
const METER_TYPE = "meter";
const THERM_TYPE = "thermometer";
const LED_TYPE = "led";

g_RGB_Red   <- [255, 0, 0];
g_RGB_Green <- [0, 255, 0];
g_RGB_Blue  <- [0, 0, 255];
g_RGB_Off   <- [0, 0, 0];
g_RGB_White <- [255, 255, 255];

function noopnoparams() {};  //TODO: This shouldn't be necessary but is until imp support ticket #3276 is resolved

//TODO: should we use the Override impwrapper to redirect all logs here?
/*PORT_UART_DEBUG.configure(115200, 8, PARITY_NONE, 1, NO_CTSRTS, function(){
  server.log("Received data from Debug UART");
  server.log("\t" + PORT_UART_DEBUG.readstring())
});*/

if(time() == DEVICE_STUCK_CLOCK) {
  server.error("RTC is NOT running - this is likely a hardware issue...")
}

//Instantiate MessageManager first so that our other classes that need it have access
g_MM <- MessageManagerExtended({
    "messageTimeout": 2
    "lowMemoryThreshold": 15000
    "firstMessageID": deviceSpiFlash[EVENTS].last({"id": 0}).id
});

//MessageManager middleware for checking to see if we should send/fail the message
g_MM.beforeSend(function(message, send, drop){
    //Check if we are running below our defined low-memory threshold
    local memoryfree = imp.getmemoryfree();
    if (memoryfree < MM_LOW_MEMORY_THRESHOLD) drop(false, "Below low-memory threshold "+memoryfree+" < "+MM_LOW_MEMORY_THRESHOLD);
});

g_MM.onTimeout(function(message, wait, fail){
    if (typeof fail == TYPE_FUNCTION) {
        fail();
    }
});

g_MM.on("rpc", rpcExec)

//Instantiate Device class
g_Device <- Device.init(deviceSpiFlash);

//Set up I2C Port and IOExpander
PORT_I2C.configure(CLOCK_SPEED_400_KHZ);
g_IOExpander <- SX1509.init(PORT_I2C, ADDRESS_SX1509);

//Instantiate Breaker
g_Breaker <- ETN_Breaker.init(PIN_DO_BREAKER_OPEN, PIN_DO_BREAKER_CLOSE, PIN_DI_BREAKER_L1_STATUS, PIN_DI_BREAKER_L2_STATUS, PIN_DI_BREAKER_DRIVE_READY, ExpGPIO(g_IOExpander, BREAKER_UNDERVOLTAGE_RELEASE_ENABLE), breakerSpiFlash);
g_BreakerNumPoles <- g_Breaker.getSPIFlashData(STATIC_DATA).numPoles;

//Set up the breaker onStateChanged function
g_Breaker.onStateChanged(function(newStatus, oldStatus, stateChangeReason) {
  DataManager.dynamicData(BREAKER_STATE_CHANGED, [oldStatus, newStatus, stateChangeReason]);
}, true);

modbusMaster <- ModbusMaster(PORT_UART_EV, 115200, 8, PARITY_NONE, 1)
g_EVSE <- ETN_EVSE.init({
    "modbusMaster"      : modbusMaster,
    "address"           : 0x02,
    "pollOnInit"        : false,
    "statisticsLogger"  : evseSpiFlash[STATISTICS],
    "mm"                : g_MM
});

//IMPORTANT: If the EV micro fails, we take over the g_Breaker onStateChanged function and override it to always try and keep the breaker open for safety
g_EVSEMicroFailedTimer <- imp.wakeup(0.0, function(){});
function reportMicroFailure(payload){
    imp.cancelwakeup(g_EVSEMicroFailedTimer);
    g_MM.send("EV_MICRO_FAILURE", payload, null, null, {
        "onReply": function(message, reply) {
            if ("success" in reply && reply.success == true) {
                server.log("EV Micro Status and Breaker status successfully set in Firebase")
            } else {
                server.log("EV Micro Status and Breaker status UNSUCCESSFULLY set in Firebase")
                g_EVSEMicroFailedTimer = imp.wakeup(60, function(){
                    server.log("Attempting to report micro failure again because it failed the last time writing to Firebase")
                    reportMicroFailure(payload);
                })
            }
        },
        "onFail": function(message, err) {
            server.log("EV Micro Status and Breaker status unsuccessfully sent to Agent")
            g_EVSEMicroFailedTimer = imp.wakeup(60, function(){
                server.log("Attempting to report micro failure again because it failed the last time sending to the Agent")
                reportMicroFailure(payload);
            })
        }
    })
}

function attemptBreakerOpen(){
    //Attempt to open breaker and send result to Agent/Firebase
    local payload = {
        "microStatus": false, //"false" means that EV Micro has failed
        "breakerStatus": true //"true" means that breaker is closed, "false" means that breaker is open (same as breaker/dynamicData/state)
    }

    g_Breaker._remoteOperate(ETN_BREAKER_OPEN)
    .then(function(data){
        server.log("Breaker successfully opened!")
        return Promise.resolve(false); // "false" for breaker status opened
    })
    .fail(function(data){
        if (typeof data == TYPE_STRING && data == ETN_BREAKER_REMOTE_OPERATE_ERROR_ALREADY_IN_DESIRED_STATE) {
            return Promise.resolve(false);
        }

        server.log("Breaker still closed after attempt to open!")
        return Promise.resolve(true); // "true" for breaker status closed
    })
    .finally(function(breakerStatus){
        server.log(".finally breaker status: "+breakerStatus)

        payload.breakerStatus = breakerStatus;
        reportMicroFailure(payload);
    })
}

g_EVSEMicroFailed <- false;
g_EVSE.onMicroFailure(function(){
    server.log("EV MICRO HAS FAILED, OVERWRITING BREAKER ONSTATECHANGED AND KEEPING BREAKER OPEN")
    g_EVSEMicroFailed = true;
    g_EVSE.cancelPolling();

    //NOTE: For a two pole breaker, if the breaker opens, this is sometimes called
    //      twice (once per pole, so we immediately get a "breaker closed" followed
    //      by a "breaker open"). We can fix with debouncing, but not necessary at this time.
    g_Breaker.onStateChanged(function(newStatus, oldStatus, stateChangeReason){
        DataManager.dynamicData(BREAKER_STATE_CHANGED, [oldStatus, newStatus, stateChangeReason]);
        if (newStatus == true) { //closed
            server.log("EV MICRO HAS FAILED AND BREAKER CLOSED -- OPENING NOW!")
            attemptBreakerOpen();
        } else {
            local payload = {
                "microStatus": false, //"false" means that EV Micro has failed
                "breakerStatus": false //"false" means that breaker is open (same as breaker/dynamicData/state)
            }

            reportMicroFailure(payload);
        }
    }, true)
})

g_DRManager <- DemandResponseManager.init(g_MM, g_EVSE, "evse");

function evseError(error){
    if(typeof(error) == TYPE_ARRAY){
        local errorData = error.slice(1);
        errorData = arrayToString(errorData)
        server.error(format("Received Error 0x%.2X%.2X with data %s", error[0][0], error[0][1], errorData))
    } else{
        server.error(error)
    }
}

function cmEVSEErrorLogger(data){
    g_CM.error("Found " + data.numErrors + " errors in EV Micro")

    for(local i=0; i<data.numErrors; i++){
        local errorTime = data.errors[i][5]
        errorTime.swap2()
        errorTime = date(errorTime.readn(INT32))  //TODO: BUG: this is actually a UINT64 but we are only using the bottom 31 bytes

        g_CM.error(format("\tError Code [0x%.2X](%d) with data [0x%.4X 0x%.4X 0x%.4X 0x%.4X]=(%.5d %.5d %.5d %.5d) at %.4d-%.2d-%.2dT%.2d:%.2d:%.2d (%d)",
                            data.errors[i][0], data.errors[i][0],
                            data.errors[i][1], data.errors[i][2], data.errors[i][3],  data.errors[i][4],
                            data.errors[i][1], data.errors[i][2], data.errors[i][3],  data.errors[i][4],
                            errorTime.year, errorTime.month+1, errorTime.day,  errorTime.hour, errorTime.min, errorTime.sec,
                            errorTime.time))
    }

}

// *************************************************
// Reset other micros if HW reset is hit on imp
// *************************************************
if(hardware.wakereason() == WAKEREASON_HW_RESET){
    server.log("RESET by button on breaker - resetting non-imp Micros")
    g_EVSE.reset()
        .then(function(data){
            server.log("EVSE RESET.")
        })

    PIN_DO_MSP430_RESET.configure(DIGITAL_OUT, 0);
    imp.sleep(0.0000025);
    PIN_DO_MSP430_RESET.write(1)
    imp.sleep(0.015)  //Allow the meter to come back up - right now the UART is glitching for ~11.5ms
}

g_EVSEReadingErrors         <- false
g_EVSEChangedRegisterBuffer <- [];
g_EVSEChangedRegisterTimer  <- imp.wakeup(0.0, function(){});

g_EVSE.onRegisterChanged(function(registerIndex, value, oldValue, ts){
    local address = (ETN_EVSE_HOLDING_REGISTER_ADDRESSES[registerIndex*2] << 8) | ETN_EVSE_HOLDING_REGISTER_ADDRESSES[registerIndex*2 + 1]
    local payload = [address, value];

    g_EVSEChangedRegisterBuffer.push(payload);
    imp.cancelwakeup(g_EVSEChangedRegisterTimer);
    g_EVSEChangedRegisterTimer = imp.wakeup(0.25,function(){
        local buffer = g_EVSEChangedRegisterBuffer;
        g_EVSEChangedRegisterBuffer = [];
        g_MM.send("onMultiRegisterChanged", buffer, null, null, {
            "onFail": function(message, err, reply){
                server.log("onMultiRegisterChanged failed: "+err);
            }
        })
    })

@if DEBUG == true

    local logStr = format("Register [0x%.4X] = ", address)

    if(typeof(value) == TYPE_ARRAY)
        logStr += arrayToString(value) + "\n"
    else if(typeof(value) == TYPE_BLOB)
        logStr += arrayToHexString(value) + "\n"
    else
        logStr += format("%s = 0x%.4X\n", value.tostring(), value)

    server.log(logStr)

@end

    if(registerIndex == ETN_EVSE_MBREG_ERROR_COUNT && value > 0 && g_EVSEReadingErrors == false){
        g_EVSEReadingErrors = true;
        g_EVSE.readErrors()  // Can be set to true for testing
        .then(function(data){
            cmEVSEErrorLogger(data)
        })
        .fail(function(error){
            g_CM.error(error)
        })
        .finally(function(data){
            g_EVSEReadingErrors = false      //Prevent an async race condition where we over-read the errors that are in the board because out polling hits while we are also in the middle of reading errors
        })
    }
})


@if EV_REGRESSION_TEST == true

// Modbus passthrough for the VTI Regression Test Equipment
PORT_UART_DEBUG.settxfifosize(259);
PORT_UART_DEBUG.setrxfifosize(259);
PORT_UART_DEBUG.configure(115200, 8, PARITY_NONE, 1, NO_CTSRTS, function(){
    local chunk = PORT_UART_DEBUG.readstring(259)
    local frame = ""
    while(chunk != ""){
        imp.sleep(0.001)
        frame += chunk
        chunk = PORT_UART_DEBUG.readstring(259)
    }

    server.log("======================= " + frame.len())
    server.log(arrayToHexString(frame))
    modbusMaster._uartPromise.write(frame, 0.700)
        .then(function(response) {
            PORT_UART_DEBUG.write(response)
            server.log(arrayToHexString(response))
            server.log("------------------------")
        }.bindenv(this))
        .fail(function(error){
            server.log("passthrough error - " + error)
        }.bindenv(this))
})

@end

// ************************************************
// Bar Graph LEDs
// ************************************************

PIN_DO_SYNCRONOUS_BLINKING.configure(DIGITAL_OUT, 1)
g_Bargraph <- BargraphRGB.init([ //This could probably be built by a for loop and save a little bit of code space if needed?
  [ExpGPIO(g_IOExpander, LED_0_RED).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_0_GREEN).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_0_BLUE).configure(ExpGPIO.LED_OUT)],
  [ExpGPIO(g_IOExpander, LED_1_RED).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_1_GREEN).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_1_BLUE).configure(ExpGPIO.LED_OUT)],
  [ExpGPIO(g_IOExpander, LED_2_RED).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_2_GREEN).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_2_BLUE).configure(ExpGPIO.LED_OUT)],
  [ExpGPIO(g_IOExpander, LED_3_RED).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_3_GREEN).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_3_BLUE).configure(ExpGPIO.LED_OUT)],
  [ExpGPIO(g_IOExpander, LED_4_RED).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_4_GREEN).configure(ExpGPIO.LED_OUT), ExpGPIO(g_IOExpander, LED_4_BLUE).configure(ExpGPIO.LED_OUT)]
], PIN_DO_SYNCRONOUS_BLINKING, bargraphSpiFlash)

function hsvToRgb(h, s, v){
  local r, g, b;

  local i = math.floor(h * 6);
  local f = h * 6 - i;
  local p = v * (1 - s);
  local q = v * (1 - f * s);
  local t = v * (1 - (1 - f) * s);

  switch(i % 6){
    case 0: r = v, g = t, b = p; break;
    case 1: r = q, g = v, b = p; break;
    case 2: r = p, g = v, b = t; break;
    case 3: r = p, g = q, b = v; break;
    case 4: r = t, g = p, b = v; break;
    case 5: r = v, g = p, b = q; break;
  }

  //math.floor(x+.5) is the same as rounding (which squirrel doesn't have)
  // server.log(h + " " + s + " " + v + " " + r + " " + g + " " + b)
  return [
    math.abs(math.floor(r * 255 + 0.5)),
    math.abs(math.floor(g * 255 + 0.5)),
    math.abs(math.floor(b * 255 + 0.5)),
  ]
}

function setBargraphToMeterData(mAp0, mAp1){
  local maxCurrent = max(math.fabs(mAp0), math.fabs(mAp1))/1000.0
  maxCurrent = (maxCurrent < 0.05 ? 0.0 : maxCurrent);
  local bargraphOverloadLimit = ("_staticData" in g_Breaker && g_Breaker._staticData != null && "ratedCurrent" in g_Breaker._staticData ? g_Breaker._staticData.ratedCurrent : 30); //TODO: do we calculate this globally once or do everytime we are in this function so that we always have the latest data?  //TODO: BUG: This should be referencing a SPIFLash configuration option...

  g_Bargraph.fill(g_RGB_Off)

  if(maxCurrent >= 0.025){    // 3 Watt load at 120V
    local percentCurrent = maxCurrent / bargraphOverloadLimit;
    local h = 120/360.0 -  percentCurrent/3.0
    h = h < 0.0 ? 0.0 : h
    local color = hsvToRgb(h, 1, 0.75);
    local numLEDs = map(maxCurrent, 0.0, bargraphOverloadLimit, 0.0, 4.175).tointeger()
    g_Bargraph.fill(color, 0, numLEDs);
  }

  if(maxCurrent > bargraphOverloadLimit) g_Bargraph.draw(true);
  else g_Bargraph.draw();
}

// *************************************************
// Identify Button
// *************************************************
g_blinkupTimer <- imp.wakeup(RAND_MAX, noopnoparams);    //TODO: BUG: filed imp support ticket #3276 - confirmed that imp.wakeup is overzealous on the number of params but bug remains in latest impOS..
btnHeldTimer <- imp.wakeup(0.0, function(){})
g_BtnIdentify <- Button.init(PIN_DI_BUTTON_IDENTIFY, DIGITAL_IN_PULLUP, Button.NORMALLY_HIGH);
g_BtnIdentify.onPress(function(){
    DataManager.dynamicData(BUTTON_STATE_CHANGED, [true]);

    readAccelAndSetEVSEDisplayOrientation();

    g_EVSE.readErrors(true)
    .then(cmEVSEErrorLogger)
    .fail(function(error){
        g_CM.error(error)
    })

    btnHeldTimer = imp.wakeup(10.0, function(){
        server.log("BUTTON Held for 10 seconds - resetting EEPROM")
        g_EVSE.readRegister(ETN_EVSE_MBREG_PERMANENT_ERROR_FLAG)
        .then(function(data){
            server.log("Permanent Error Flag is set to " + data)

            if(data != 0){
                server.log("Resetting EVSE EEPROM to clear a permenant error")
                g_EVSE.resetEEPROM()
            }
        })
    })

    //TODO: BUG: we should be using something stored in SPIFlash to determine if this is the correct behavior.  John H. also requested some behavior here (although I don't recall exactly what it was...)
    imp.cancelwakeup(g_blinkupTimer);
    g_CM.setBlinkUpBehavior(ConnectionManager.BLINK_ALWAYS);
    g_blinkupTimer = imp.wakeup(60.0, function(){
        g_CM.setBlinkUpBehavior(ConnectionManager.BLINK_ON_DISCONNECT);
    });

    local rssi = imp.rssi();

    //NOTE: Here we remap RSSI to a color and a bar - we consider -67 a "100%"
    //      signal and -87 a "0%" signal (which gives 21 values to consider).
    //      Anything above 100% shows as 5 green bars, anything below 0% makes
    //      the LED blink. If we are offline, blink the center 3 LEDs RED.
    //
    //TODO: BUG: we've found that RSSI's above -30 can actually "drown out" the imp's WiFi to the point that it can't communicate reliably - we probably need to consider that in the code below.
    if(g_CM.isConnected()){
        local percentSignal = (rssi+87)/20.0 //(we use 20 instead of 21) to make the rounding work out in a way that is nice and distributed
        percentSignal = percentSignal > 1 ? 1 : percentSignal
        percentSignal = percentSignal < 0 ? 0 : percentSignal

        local h = percentSignal/6.0 // 1/3 = Green in HSV color.  0 = red
        h = h < 0.0 ? 0.0 : h
        local color = hsvToRgb(h + (0.5), 1.0, 1.0);

        local bar = math.floor((rssi+87)/4)
        local blinking = bar < 0 ? true : false;
        bar = bar < 0 ? 0 : bar;
        bar = bar > 4 ? 4 : bar;

        g_Bargraph.fill(g_RGB_Off).fill(color, 0, bar, blinking).draw()
    } else {
        g_Bargraph.set(0,g_RGB_Off).fill(g_RGB_Red,1,3,true).set(4, g_RGB_Off).draw()
    }
});

g_BtnIdentify.onRelease(function(){
    DataManager.dynamicData(BUTTON_STATE_CHANGED, [false]);
    imp.cancelwakeup(btnHeldTimer);

    if (g_Meter._intervalData[METER_INTERVAL_CURRENT_PHASE_A] != null) {
      setBargraphToMeterData(g_Meter._intervalData[METER_INTERVAL_CURRENT_PHASE_A],g_Meter._intervalData[METER_INTERVAL_CURRENT_PHASE_B]);
    } else {
      setBargraphToMeterData(0.0, 0.0);
      //server.error("Button onRelease: meter interval data is bad!")
    }
});

//NOTE: The call to Button.debounce() will fire the onPress or onRelease handler
//      that was provided to the Button class on instantiation. Considering
//      the update to the button Dynamic Data on Firebase is handled there, this
//      works fine (but, I think the future addition of a Button.getState()
//      method could improve the Button class for the reasons described here: https://github.com/EatonGMBD/emcb-beta-imp-firmware/pull/110)
imp.wakeup(0.5, g_BtnIdentify._debounce.bindenv(g_BtnIdentify));

// ************************************************
// Configure the g_TempSensor Sensor
// ************************************************
g_TempSensor <- TMP1x2.init(PORT_I2C, ADDRESS_TMP102);

// ************************************************
// accelerometer
// ************************************************
g_Accelerometer <- LIS3DH.init(PORT_I2C, ADDRESS_LIS3DH, PIN_DI_IRQ_ACCEL);

// Configure accelerometer
g_Accelerometer.setDataRate(100);
g_Accelerometer.configureInterruptLatching(true);

//TODO: we are not currently using any of the accelerometer interrupts - we really should be monitoring for things like excessive vibration and sending events based on that.
// Set up a free-fall interrupt
g_Accelerometer.configureFreeFallInterrupt(true);

// Set up a double-click interrupt
g_Accelerometer.configureClickInterrupt(true, LIS3DH_DOUBLE_CLICK);

g_EVSEDisplayTimer <- imp.wakeup(0.0, function(){});
function accelInterruptHandler() {
  // Upon accelerometer event, let's first read accelerometer to determine orientation
  readAccelAndSetEVSEDisplayOrientation();

  if (PIN_DI_IRQ_ACCEL.read() == 0) return;

  // Get + clear the interrupt + clear
  local data = g_Accelerometer.getInterruptTable();

  // Check what kind of interrupt it was
  if (data.int1) {
    server.log("Free Fall");
  }

  if (data.doubleClick) {
    // Flash white twice
    g_Bargraph.configureBlocking([g_RGB_White, g_RGB_White, g_RGB_White, g_RGB_White, g_RGB_White], 0.25);
    imp.wakeup(0.5, function(){
      g_Bargraph.configureBlocking([g_RGB_White, g_RGB_White, g_RGB_White, g_RGB_White, g_RGB_White], 0.25);
    })
  }

  //TODO: Add accelerometer dynamic data
}

// Function for reading accelerometer and determining how to orient OLED display
function readAccelAndSetEVSEDisplayOrientation() {
    g_Accelerometer.getAccel(function(val) {
        local orientation = (val.z > 0.5 ? ETN_EVSE_ENUM_DISPLAY_ACCELEROMETER_ON_INVERTED : ETN_EVSE_ENUM_DISPLAY_ACCELEROMETER_ON);

        g_EVSE.setSingleRegister(ETN_EVSE_MBREG_DISPLAY_ACCELEROMETER, orientation)
        .fail(function(data){
            server.log("Failed setting EVSE display accelerometer register on")
        })

        imp.cancelwakeup(g_EVSEDisplayTimer);
        g_EVSEDisplayTimer = imp.wakeup(120, function(){
            g_EVSE.setSingleRegister(ETN_EVSE_MBREG_DISPLAY_ACCELEROMETER, ETN_EVSE_ENUM_DISPLAY_ACCELEROMETER_OFF)
            .fail(function(){
                server.log("Failed setting EVSE display accelerometer register off")
            })
        })
    })
}

// Read the accelerometer on imp reboot
readAccelAndSetEVSEDisplayOrientation();

//Set accelerometer interrupt handler
PIN_DI_IRQ_ACCEL.configure(DIGITAL_IN, accelInterruptHandler);

// *************************************************
// Meter
// *************************************************
g_Meter <- SentecMeter.init({
    "uart"                  : PORT_UART_METER,
    "dataReadyPin"          : PIN_DI_IRQ_METER,
    "staticDataSafeFile"    : meterSpiFlash[STATIC_DATA],
    "configSafeFile"        : meterSpiFlash[CONFIGURATION],
    "statisticsLogger"      : meterSpiFlash[STATISTICS],
    "mm"                    : g_MM
});

g_Meter.setStatusInterrupts(false, false, false)
.fail(g_Meter.logError);

/*g_Meter.command(GET_STATUS_INTERRUPTS)
.then(function(irq) {
  if(irq == METER_STATUS_INTERRUPT_NONE) server.log("No Interrupts set on Sentec Meter")
  else {
    local arr = [];
    if(irq & METER_STATUS_INTERRUPT_PERIODIC) arr.push("Periodic Data Ready"); //1
    if(irq & METER_STATUS_INTERRUPT_WAVEFORM) arr.push("Waveform Data Ready"); //2
    if(irq & METER_STATUS_INTERRUPT_PERIODIC_INCREMENTAL) arr.push("Periodic Incremental Data Ready"); //4
    server.log("Sentec Meter Interrupts set for: "+arrayToString(arr));
  }
})
.fail(g_Meter.logError);*/

/*g_Meter.command(GET_FIRMWARE_REVISION)
.then(function(data){
  local firmwareRev = data[0]
  local dirtyBuild = data[1]

  server.log("Sentec g_Meter git Firmware Revision = " + firmwareRev + " (https://bitbucket.org/sentec/eaton-emcb-development/commits/all?search=" + firmwareRev + ")");
  if(dirtyBuild == true) {
    server.log("\t[WARNING]: There were uncommited changes when the binary was built.")
  }

})
.fail(g_Meter.logError);*/

/*g_Meter.command(GET_PROTOCOL_REVISION)
.then(function(protocolRev){
  server.log("Sentec g_Meter Protocol Revision = " + protocolRev)
})
.fail(function(error){
  if(typeof(error) == TYPE_ARRAY && error[0] == METER_ERROR_PROTOCOL_REVISION_MISMATCH) server.error("PROTOCOL REVISION HAS CHANGED - UPDATE IMP FIRMWARE AS NEEDED!");
  else server.error("UNKNOWN ERROR WHILE GETTING SENTECMETER PROTOCOL REVISION - "+error);
})*/

const PERIODIC_DATA_INTERVAL = 10;
g_MeterSentZeroOnce <- false;
g_MeterIncrementalMeasurements <- ["q1mJp0", "q2mJp0", "q3mJp0", "q4mJp0", "q1mVARsp0", "q2mVARsp0", "q3mVARsp0", "q4mVARsp0", "q1mJp1", "q2mJp1", "q3mJp1", "q4mJp1", "q1mVARsp1", "q2mVARsp1", "q3mVARsp1", "q4mVARsp1"];
g_MeterIncrementalFirstIgnored <- false;
g_MeterIncreaseOneSecondDataRate <- false;
lastPeriodicDataSend <- 0;
slowDownPeriodicData <- false;
periodicDataBackoffTimer <- imp.wakeup(0, noopnoparams)

g_CM.onDisconnect(function(...){
  periodicDataBackoffTimer = imp.wakeup(300, function(){
    slowDownPeriodicData = true;
    lastPeriodicDataSend = hardware.millis()
  })
})

g_Meter.onPeriodicData(function(data){
    local maxCurrent    = max(math.abs(data.mAp0), math.abs(data.mAp1))
    local maxCurrent64  = blob(8);
    local LL            = data.LLp01mV
    local LL64          = blob(8);

    //server.log(format("Current Phase A = %f ////// Current Phase B = %f", data.mAp0/1000.0, data.mAp1/1000.0))

    maxCurrent64.writen(maxCurrent, INT32);
    maxCurrent64.swap2();
    LL64.writen(LL, INT32);
    LL64.swap2();

    if (!g_EVSEMicroFailed) {
        g_EVSE.setSingleRegister(ETN_EVSE_MBREG_LAST_READ_CURRENT, maxCurrent64)
        .then(function(data){
            // server.log("Set Last read current = " + maxCurrent + " A")
            return g_EVSE.setSingleRegister(ETN_EVSE_MBREG_LAST_READ_VOLTAGE, LL64)
        }.bindenv(this))
        // .then(function(ret2){
        //     // server.log("Set Last read voltage = " + LL/1000.0 + " V")
        // })
        .fail(function(data){
            server.error("Setting EVSE current/voltage failed")
            server.error(data)
        })
    }

    if (g_BtnIdentify.getState() == false) {
        setBargraphToMeterData(data.mAp0, data.mAp1);
    }

    if (g_CM.isConnected()) {
        imp.cancelwakeup(periodicDataBackoffTimer)
        slowDownPeriodicData = false;

        if (data.sequence % 10 == 0) {
            g_MM.send("METER_PERIODIC", data); //Only send complete periodic data 1 every 10 seconds. //TODO: make configurable
        }
    } else {
        // If we are disconnected, we have to slow down our flash writes to ensure our wear story and amount of storage is valid
        // if(slowDownPeriodicData == true && hardware.millis() - lastPeridicDataSend > 900000){ // After 5 minutes of disconnection, only send data every 15 minutes
        //     lastPeridicDataSend = hardware.millis()
        //     g_MM.send("METER_PERIODIC", data);
        // } else {
        //     if (data.sequence % 10 == 0){ //TODO: make configurable
        //     g_MM.send("METER_PERIODIC", data);
        //     }
        // }
    }
})

g_Meter.onPeriodicIncrementalData(function(data){
  // server.log(format("Get Periodic Data Incremental: Seq-%d, Period-%d", data.sequence, data.period));

    local p0 = data.mJp0 > 0 ? data.mJp0 : 0
    local p064 = blob(8);
    local p1 = data.mJp1 > 0 ? data.mJp1 : 0
    local p164 = blob(8);

    //TODO: Test that this writen followed by swap2() actually works!
    p064.writen(p0, INT32);
    p064.swap2();
    p164.writen(p1, INT32);
    p164.swap2();

    if (!g_EVSEMicroFailed) {
        g_EVSE.setSingleRegister(ETN_EVSE_MBREG_ENERGY_DELTA_PHASE1, p064)
        .then(function(ret1){
            // server.log("Energy Delta Phase 1 set to " + p0 + " mJ")
            return g_EVSE.setSingleRegister(ETN_EVSE_MBREG_ENERGY_DELTA_PHASE2, p164)
        }.bindenv(this))
        // .then(function(ret2){
        //     // server.log("Energy Delta Phase 2 set to " + p1 + " mJ")
        // })
        .fail(function(data){
            server.error("Setting EVSE energy delta failed")
            server.error(data)
        })
    }

    if (!g_MeterIncrementalFirstIgnored) {
        g_MeterIncrementalFirstIgnored = true;
        return;
    }

    local allZeros = true;
    for (local i = 0; i < g_MeterIncrementalMeasurements.len(); i++) {
        if (data[g_MeterIncrementalMeasurements[i]] != 0) {
            allZeros = false;
            break;
        }
    }

    //NOTE: Becuase we aren't doing anything with zeros on the Agent *after* we
    //      get the first one, we should stop sending them up (it's a huge waste
    //      of bandwidth).
    if (g_CM.isConnected()) {
        if ((!allZeros || (allZeros && !g_MeterSentZeroOnce)) && (g_MeterIncreaseOneSecondDataRate || (!g_MeterIncreaseOneSecondDataRate && data.sequence % 10 == 0))) {
            local retries = 0;
            g_MM.send("METER_INCREMENTAL_DATA", data, null, null, {
                "onReply": function(message, data) {
                    if (allZeros && !g_MeterSentZeroOnce) g_MeterSentZeroOnce = true;
                    if (!allZeros) g_MeterSentZeroOnce = false;
                },
                "onFail": function(message, err, retry){
                    // retries++;
                    // if (retries < 2) retry();
                    // if (!retry()) server.log("Couldn't send incremental data") //TODO: Figure out how to limit this to one retry, rather than the number of retries that MessageManager is configured to try
                }
            })
        }
    }
})

@include once  "src/Functions/Meter/Waveforms.nut"
@include once  "src/Implementation/Meter/Waveforms.nut"

/*g_Meter.onInterrupt(function(){ //TODO: BUG: this is being called far too often and we need to figure out why...
    g_EVSE.disable()    //TODO: Only for Short Circuit test
    server.log("DISABLING EVSE FOR WAVEFORM IRQ!!!")
})*/

// @include once "src/Implementation/EVSE/FirmwareUpgrade.device.nut"

g_DataManager <- DataManager.init({
  [ACCEL_TYPE] = g_Accelerometer,
  [BRKR_TYPE] = g_Breaker,
  [DEVICE_TYPE] = g_Device,
  [METER_TYPE] = g_Meter,
  [EVSE_TYPE] = g_EVSE,
  [LED_TYPE] = g_Bargraph,
  [THERM_TYPE] = g_TempSensor
}, deviceSpiFlash[CONFIGURATION],false,false);

// ---------------------------------------
// -- Basic user presence system stuff ---
// --------------------------------------{
g_ConnectedUserTimers <- {};
g_Device.onUserConnect(function(uid, duration=null, connectTime=null){
  local duration = duration || USER_CONNECT_TIME; //default is 5 minutes;

  if (connectTime != null) {
    local diff = time()-connectTime;
    server.log("Last user-connected \""+uid+"\" time: "+connectTime+", diff: "+diff);
    if (diff < 0 || diff >= USER_CONNECT_TIME) {
      g_Device.disconnectUser(uid);
      return;
    } else {
      duration = USER_CONNECT_TIME-diff;
    }
  }

  server.log(format("User %s connecting for %ds", uid, duration));
  if (uid in g_ConnectedUserTimers) imp.cancelwakeup(g_ConnectedUserTimers[uid]);
  g_ConnectedUserTimers[uid] <- imp.wakeup(duration, function(){
    g_Device.disconnectUser(uid); //this removes the uid from a table in g_Device and calls the onUserDisconnect callback
  })

  g_MeterIncreaseOneSecondDataRate = true;
})

g_Device.onUserDisconnect(function(uid){
  server.log(format("User %s disconnecting", uid));
  if (!g_Device.areUsersConnected()) {
    // server.log("No more users connected, slowing down data rate (and updating device/configuration/userConnected)")
    g_MeterIncreaseOneSecondDataRate = false;
    g_DataManager.updateData(DEVICE_TYPE, "configuration", "userConnected", false);
  } else {
    local config = g_Device.getSPIFlashData(CONFIGURATION);
    if ("connectedUsers" in config) g_DataManager.updateData(DEVICE_TYPE, "configuration", "connectedUsers", config.connectedUsers, null, true);
  }
})

g_Device.loadConnectedUsers();
// ---------------------------------------
// -- Basic user presence system [END] ---
// --------------------------------------}

// ---------------------------------------
// -------- Initialization stuff ---------
// --------------------------------------{
bootacktimer <- imp.wakeup(0, noopnoparams);
function sendBootToAgent() {
  agent.on("bootack", function(data){ imp.cancelwakeup(bootacktimer);})
  imp.cancelwakeup(bootacktimer);
  bootacktimer = imp.wakeup(10, sendBootToAgent);
  agent.send("boot", null);
}

function readInitialRegisters() {
  g_EVSE.readRegister(ETN_EVSE_MBREG_FACTORY_NAMEPLATE_RATING)
  .then(function(value){
    local registerIndex = ETN_EVSE_MBREG_FACTORY_NAMEPLATE_RATING;
    local address = (ETN_EVSE_HOLDING_REGISTER_ADDRESSES[registerIndex*2] << 8) | ETN_EVSE_HOLDING_REGISTER_ADDRESSES[registerIndex*2 + 1];

    g_MM.send("onRegisterChanged", [address, value], null, null, {
      "onFail": function(message,err,retry){
        imp.wakeup(5, readInitialRegisters);
      }
    });
  })
  .fail(function(err){
      imp.wakeup(5, readInitialRegisters);
  })
}

g_InitStep <- 0;
g_InitializedBegin <- false;
g_InitializeComplete <- false;
function g_BootSequenceStep2() {
    server.log("[InitializeSequence]: Device boot sequence step 2/4")
    g_InitStep = 2;
    g_DataManager.sendAllSPIFlashDataToFirebase()
    .then(function(ignore){
        sendBootToAgent();
        imp.wakeup(2, function(){
            server.log("[InitializeSequence]: Device boot sequence step 3/4")
            g_InitStep = 3;
            setWaveformConfiguration(); //start capturing waveforms
            imp.wakeup(3,function(){
                server.log("[InitializeSequence]: Device boot sequence step 4/4")
                g_InitStep = 4;
                if (!g_EVSEMicroFailed) {
                    readInitialRegisters();
                    g_EVSE._poll();
                }
                server.log("[InitializeSequence]: Device boot sequence complete")
                g_InitStep = "Complete"

                delete getroottable().g_PreBootMemoryCheck;
                delete getroottable().g_BootSequenceStep1;
                delete getroottable().g_BootSequenceStep2;
            });
        })
    })
    .fail(function(err){
        g_InitStep = g_InitStep.tostring() + err;
        server.error("[InitializeSequence]: Error in device boot sequence step 2, retrying in 5s");
        server.error("[InitializeSequence]: Error sending SPIFlash data to Agent: "+err);
        imp.wakeup(5, g_BootSequenceStep2); //try again in 10 imp.imp.sleep(//TODO: BUG: implement this inside datamanager instead of it being out here)
    })
    .fail(function(err){
        g_InitStep = g_InitStep.tostring() + err;
    })
}

function g_BootSequenceStep1() {
    g_InitializedBegin = true;
    server.log("[InitializeSequence]: Device boot sequence step 1/4")
    g_InitStep = 1;
    g_Meter.startPolling()  //This one is important as it makes sure that we read begin reading from the meter regularly!
    imp.wakeup(1, function(){
        g_DataManager.beginAllIntervalDataTimers()
        imp.wakeup(1, g_BootSequenceStep2);
    })
}

function g_PreBootMemoryCheck(interval=1) {
    local mem = imp.getmemoryfree();

    if (!g_InitializedBegin) {
        if (mem > 12000) {
            server.log("[InitializeSequence]: Initializing")
            pollMemory();
            g_BootSequenceStep1();
        } else {
            server.log("[InitializeSequence]: Initialize pending due to insufficient memory ("+mem+" < 12000)")
            imp.wakeup(interval, g_PreBootMemoryCheck);
        }
    }
}

function pollMemory(interval=30){
    server.log("[PollFreeMemory]: "+imp.getmemoryfree() + " (init step: "+g_InitStep+")");
    // server.log("[PollFreeMemory]: "+imp.getmemoryfree() + " (init step: "+g_InitStep+", numWakeupsFailed: "+g_WakeupFailedCount+": "+g_WakeupFailedMessage+")");
    imp.wakeup(interval,pollMemory);
}

function pingAck(data) { agent.send("online", null) }
agent.on("ping", pingAck);
agent.send("online", null); //let the agent know we're online on boot

//This is what kicks off the init process (when we have enough memory)
g_PreBootMemoryCheck();

// ---------------------------------------
// -------- Initialization stuff [END] ---
// --------------------------------------}

// Loop the colors of the rainbow, starting at blue  //TODO: Optimize this function using some of the bindenv() stuff for higher performance?
for(local i=240; i <= 600; i+=10) g_Bargraph.fill(hsvToRgb(i % 360 / 360.0, 1, 1)).draw()
g_Bargraph.fill(g_RGB_Off).draw();

local currentTime = date(time(), 'u');
server.log(format("Device Booted and Squirrel Initialization Complete - %.4d-%.2d-%.2dT%.2d:%.2d:%.2d (%d).  millis=%d, Memory Free=%d, OS Version=%s", currentTime.year, currentTime.month+1, currentTime.day,  currentTime.hour, currentTime.min, currentTime.sec, time(), hardware.millis(), imp.getmemoryfree(), imp.getsoftwareversion()))
// =============================================================================
// --------------------------------------------------- END_MAIN_APPLICATION_CODE
// ============================================================================}

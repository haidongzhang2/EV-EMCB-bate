const FIREBASE_AUTO_FAIL_DEFAULT_ERROR = "Auto-Fail Firebase Message by User"

// Copyright (c) 2015 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT
class Firebase {
    // Library version
    //static version = [2,0,1];
    static KEEP_ALIVE = 60;     // Timeout for streaming

    // General
    _db = null;                 // The name of your firebase instance
    _auth = null;               // _auth key (if auth is enabled)
    _baseUrl = null;            // base url (may change with 307 responses)
    _domain = null;

    // Debugging
    _debug = null;              // Debug flag, when true, class will log errors

    // REST
    _defaultHeaders = { "Content-Type": "application/json" };

    // Streaming
    _streamingHeaders = { "accept": "text/event-stream" };
    _streamingRequest = null;    // The request object of the streaming request
    _data = null;                // Current snapshot of what we're streaming
    _callbacks = null;           // List of _callbacks for streaming request
    _keepAliveTimer = null;      // Wakeup timer that watches for a dead Firebase socket
    _promiseIncluded = null ;    // indicate if Promise library is included
    _jsonEncoderIncluded = null; // indicate if JSON Encoder library is included
    _jsonParserIncluded = null;  // indicate if JSON Parser library is included

    // Middleware
    _beforeSend         = null;
    _beforeDataReceived = null;

    /***************************************************************************
     * Constructor
     * Returns: FirebaseStream object
     * Parameters:
     *      _baseUrl - the base URL to your Firebase (https://username.firebaseio.com)
     *      _auth - the _auth token for your Firebase
     **************************************************************************/
    constructor(db, auth = null, domain = "firebaseio.com", debug = true) {
        _debug = debug;

        _db = db;
        _domain = domain;
        _baseUrl = "https://" + _db + "." + domain;
        _auth = auth;

        _data = {};

        _callbacks = {};

        _promiseIncluded = ("Promise" in getroottable());
        _jsonEncoderIncluded = ("JSONEncoder" in getroottable());
        _jsonParserIncluded = ("JSONParser" in getroottable());
    }

    /***************************************************************************
     * Attempts to open a stream
     * Returns:
     *      false - if a stream is already open
     *      true -  otherwise
     * Parameters:
     *      path - the path of the node we're listending to (without .json)
     *      uriParams - table of values to attach as URI parameters.  This can be used for queries, etc. - see https://www.firebase.com/docs/rest/guide/retrieving-data.html#section-rest-uri-params
     *      onError - custom error handler for streaming API
     **************************************************************************/
    function stream(path = "", uriParams = null, onError = null, onAuthExpired = null, converter = null) {
        // if we already have a stream open, don't open a new one
        if (isStreaming()) return false;

        if (typeof uriParams == "function") {
            onError = uriParams;
            uriParams = null;
        }
        if (onError == null) onError = _defaultErrorHandler.bindenv(this);
        _streamingRequest = http.get(_buildUrl(path, uriParams), _streamingHeaders);
        _streamingRequest.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);

        _streamingRequest.sendasync(
            _onStreamExitFactory(path, uriParams, onError, onAuthExpired, converter),
            _onStreamDataFactory(path, uriParams, onError, onAuthExpired, converter),
            NO_TIMEOUT
        );

        // Tickle the keepalive timer
        if (_keepAliveTimer) imp.cancelwakeup(_keepAliveTimer);
        _keepAliveTimer = imp.wakeup(KEEP_ALIVE, _onKeepAliveExpiredFactory(path, uriParams, onError, onAuthExpired, converter));

        // Return true if we opened the stream
        return true;
    }

    /***************************************************************************
     * Returns whether or not there is currently a stream open
     * Returns:
     *      true - streaming request is currently open
     *      false - otherwise
     **************************************************************************/
    function isStreaming() {
        return (_streamingRequest != null);
    }

    /***************************************************************************
     * Closes the stream (if there is one open)
     **************************************************************************/
    function closeStream() {
        // Kill the keepalive if it exists
        if (_keepAliveTimer) imp.cancelwakeup(_keepAliveTimer);

        // Close the stream if it's open
        if (_streamingRequest) {
            _streamingRequest.cancel();
            _streamingRequest = null;
        }
    }

    /***************************************************************************
     * Registers a callback for when data in a particular path is changed.
     * If a handler for a particular path is not defined, data will change,
     * but no handler will be called
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're listending to (without .json)
     *      callback - a callback function with two parameters (path, change) to be
     *                 executed when the data at path changes
     **************************************************************************/
    function on(path, callback) {
        if (path.len() > 0 && path.slice(0, 1) != "/") path = "/" + path;
        if (path.len() > 1 && path.slice(-1) == "/") path = path.slice(0, -1);
        _callbacks[path] <- callback;
    }

    /***************************************************************************
     * Reads a path from the internal cache. Really handy to use in an .on() handler
     **************************************************************************/
    function fromCache(path = "/") {
        local data = _data;
        foreach (step in split(path, "/")) {
            if (step == "") continue;
            if (step in data) data = data[step];
            else return null;
        }
        return data;
    }

    /***************************************************************************
     * Reads data from the specified path, and executes the callback handler
     * once complete.
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're reading
     *      uriParams - table of values to attach as URI parameters.  This can be used for queries, etc. - see https://www.firebase.com/docs/rest/guide/retrieving-data.html#section-rest-uri-params
     *      callback - a callback function with one parameter (data) to be
     *                 executed once the data is read
     **************************************************************************/
     function read(path, uriParams = null, callback = null, converter = null) {
        if (typeof uriParams == "function") {
            callback = uriParams;
            uriParams = null;
        }
        local request = http.get(_buildUrl(path, uriParams), _defaultHeaders)
        request.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);
        if (callback) {
            _processResponse(request,callback,converter);

        } else {
            return  _returnPromise(request, {"verb": "GET", "path": path}, converter);
        }

    }

    /***************************************************************************
     * Pushes data to a path (performs a POST)
     * This method should be used when you're adding an item to a list.
     *
     * NOTE: This function does NOT update firebase._data
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're pushing to
     *      data     - the data we're pushing
     **************************************************************************/
    function push(path, data, priority = null, callback = null, useStandardEncoder = false) {
        if (priority != null && typeof data == "table") data[".priority"] <- priority;
        local encodedData = (useStandardEncoder ? http.jsonencode(data) : _encodeData(data));
        local request = http.post(_buildUrl(path), _defaultHeaders, encodedData)
        request.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);
        if (callback) {
            _processResponse(request,callback);
        } else {
           return _returnPromise(request, {"verb": "POST", "path": path, "data": data});
        }

    }

    /***************************************************************************
     * Writes data to a path (performs a PUT)
     * This is generally the function you want to use
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're writing to
     *      data     - the data we're writing
     **************************************************************************/
    function write(path, data, callback = null, useStandardEncoder = false) {
        local encodedData = (useStandardEncoder ? http.jsonencode(data) : _encodeData(data));
        local request = http.put(_buildUrl(path), _defaultHeaders, encodedData)
        request.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);
        if (callback) {
            _processResponse(request,callback);
        } else {
            return _returnPromise(request, {"verb": "PUT", "path": path, "data": data});
        }

    }

    /***************************************************************************
     * Updates a particular path (performs a PATCH)
     * This method should be used when you want to do a non-destructive write
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're patching
     *      data     - the data we're patching
     **************************************************************************/
    function update(path, data, callback = null, useStandardEncoder = false) {
        local encodedData = (useStandardEncoder ? http.jsonencode(data) : _encodeData(data));
        local request = http.request("PATCH", _buildUrl(path), _defaultHeaders, encodedData)
        request.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);
        if (callback) {
            _processResponse(request,callback);
        } else {
            return _returnPromise(request, {"verb": "PATCH", "path": path, "data": data});
        }

    }

    /***************************************************************************
     * Deletes the data at the specific node (performs a DELETE)
     *
     * NOTE: This function does NOT update firebase._data
     *
     * Returns:
     *      nothing
     * Parameters:
     *      path     - the path of the node we're deleting
     **************************************************************************/
    function remove(path, callback = null) {
        local request = http.httpdelete(_buildUrl(path), _defaultHeaders)
        request.setvalidation(VALIDATE_USING_SYSTEM_CA_CERTS);
        if (callback) {
            _processResponse(request,callback);
        } else {
            return _returnPromise(request, {"verb": "DELETE", "path": path});
        }

    }


    /************ Private Functions (DO NOT CALL FUNCTIONS BELOW) ************/
    // Builds a url to send a request to
    function _buildUrl(path, uriParams = null) {
        // Normalise the /'s
        // _baseUrl = <_baseUrl>
        // path = <path>
        if (_baseUrl.len() > 0 && _baseUrl[_baseUrl.len()-1] == '/') _baseUrl = _baseUrl.slice(0, -1);
        if (path.len() > 0 && path[0] == '/') path = path.slice(1);

        local url = _baseUrl + "/" + path + ".json";

        if(typeof(uriParams) != "table") uriParams = {}


        local quoteWrappedKeys = [
            "startAt",
            "endAt" ,
            "equalTo",
            "orderBy"
        ]

        foreach(key, value in uriParams){
            if(quoteWrappedKeys.find(key) != null && typeof(value) == "string") {
                if(value[0] == '"') value = value.slice(1);  //Ensure we haven't already quote wrapped this key
                if(value[value.len()-1] == '"') value = value.slice(0, -1);
                uriParams[key] = "\"" + value + "\""
            }
        }

        //TODO: Right now we aren't doing any kind of checking on the uriParams - we are trusting that Firebase will throw errors as necessary

        // Use instance values if these keys aren't provided
        if(!("ns" in uriParams)) uriParams.ns <- _db;
        if(!("auth" in uriParams) && _auth !=null) uriParams.auth <- _auth ;

        url += "?" + http.urlencode(uriParams);
        return url;
    }

    // Default error handler
    function _defaultErrorHandler(errors) {
        foreach (error in errors) {
            if ("code" in error) _logError("ERROR " + error.code + ": " + error.message);
            else {
              _logError("ERROR -- Expected key \"code\" not found in error (printing contents): "+error);
              if ("printObject" in getroottable()) printObject(error);
            }
        }
    }

    // Stream Callback
    function _onStreamExitFactory(path, uriParams, onError, onAuthExpired, converter) {
        return function(resp) {
            _streamingRequest = null;
            if ((resp.statuscode == 307 || resp.statuscode == 503) && "location" in resp.headers) { //TODO: Not sure if this would have saved us from the migration error, but it might have...
                // set new location
                local location = resp.headers["location"];
                local p = location.find("." + _domain);
                p = location.find("/", p);
                _baseUrl = location.slice(0, p);
                return imp.wakeup(0, function() { stream(path, uriParams, onError, onAuthExpired, converter); }.bindenv(this));
            } else if (resp.statuscode == 28 || resp.statuscode == 429) {
                // if we timed out, just reconnect after a small delay
                imp.wakeup(0, function() { return stream(path, uriParams, onError, onAuthExpired, converter); }.bindenv(this));
            } else if(resp.statuscode == 200){
                _onStreamDataFactory(path, uriParams, onError, onAuthExpired, converter)(resp.body)
                server.log("stream closed")
            } else {
                // Otherwise log an error (if enabled)
                _logError("Stream closed with error " + resp.statuscode);
                _logError(_encodeData(resp));
                //TODO: BUG: I think there are still a few edge cases where things can go badly for us and our reconnect logic doesn't work.  If we see a Firebase error that we don't expect, I'm not sure what line of code is restarting our stream (although something seems to be)....  We really probably need a watchdog timer to rejigger everything if we run into something unexpected...
                // Invoke our error handler
                imp.wakeup(0, function() { onError(resp); });
            }
        }.bindenv(this);
    }

    // Stream Callback
    //TODO: We are not currently explicitly handling https://www.firebase.com/docs/rest/api/#section-streaming-cancel and https://www.firebase.com/docs/rest/api/#section-streaming-auth-revoked
    function _onStreamDataFactory(path, uriParams, onError, onAuthExpired, converter) {
        return function(messageString) {
            // Tickle the keep alive timer
            if (_keepAliveTimer) imp.cancelwakeup(_keepAliveTimer);
            _keepAliveTimer = imp.wakeup(KEEP_ALIVE, _onKeepAliveExpiredFactory(path, uriParams, onError, onAuthExpired, converter));

            local messages = _parseEventMessage(messageString, converter);
            foreach (message in messages) {
                if(message.event == "auth_revoked"){
                    if (typeof(onAuthExpired) == "function"){
                        _auth = onAuthExpired()
                        imp.wakeup(0, function() {
                            closeStream()
                            stream(path, uriParams, onError, onAuthExpired);
                        }.bindenv(this));
                    } else {
                        // Otherwise log an error (if enabled)
                        _logError("Stream closed with error " + resp.statuscode);
                        _logError(_encodeData(message));

                        // Invoke our error handler
                        imp.wakeup(0, function() { onError(resp); });
                    }
                    continue
                }
                // Update the internal cache
                _updateCache(message);

                // Check out every callback for matching path
                foreach (path,callback in _callbacks) {

                    if (path == "/" || path == message.path || message.path.find(path + "/") == 0) {
                        // This is an exact match or a subbranch

                        // Create local instance of message for the callback
                        local thisMessage = message;
                        local thisCallback = callback;
                        imp.wakeup(0, function() { thisCallback(thisMessage.path, thisMessage.data); }.bindenv(this));
                    } else if (message.event == "patch") {
                        // This is a patch for a (potentially) parent node
                        foreach (head,body in message.data) {
                            local newmessagepath = ((message.path == "/") ? "" : message.path) + "/" + head;
                            if (newmessagepath == path) {
                                // We have found a superbranch that matches, rewrite this as a PUT
                                local subdata = _getDataFromPath(newmessagepath, message.path, _data);
                                local thisCallback = callback;
                                imp.wakeup(0, function() { thisCallback(newmessagepath, subdata); }.bindenv(this));
                            }
                        }
                    } else if (message.path == "/" || path.find(message.path + "/") == 0) {
                        // This is the root or a superbranch for a put or delete
                        local subdata = _getDataFromPath(path, message.path, _data);

                        // Create local instance of path and callback
                        local thisPath = path;
                        local thisCallback = callback;
                        imp.wakeup(0, function() { thisCallback(thisPath, subdata); }.bindenv(this));
                    }
                }
            }
        }.bindenv(this);
    }

    // No keep alive has been seen for a while, lets reconnect
    function _onKeepAliveExpiredFactory(path, uriParams, onError, onAuthExpired, converter) {
        return function() {
            _logError("Keep alive timer expired. Reconnecting stream.")
            closeStream();
            stream(path, uriParams, onError, onAuthExpired, converter);
        }.bindenv(this);
    }

    // parses event messages
    function _parseEventMessage(text, converter) {
        // split message into parts
        local alllines = split(text, "\n");
        if (alllines.len() < 2) return [];
        local returns = [];
        for (local i = 0; i < alllines.len(); ) {
            local lines = [];

            lines.push(alllines[i++]);
            lines.push(alllines[i++]);
            if (i < alllines.len() && alllines[i+1] == "}") {
                lines.push(alllines[i++]);
            }

            // Check for error conditions
            if (lines.len() == 3 && lines[0] == "{" && lines[2] == "}") {
                local error = _parseData(text);
                _logError("Firebase error message: " + error.error);
                continue;   //The continue operator jumps to the next iteration of the loop skipping the execution of the following statements.
            }

            // get the event
            // The server may send the following events:
            // put:  The JSON-encoded data will be an object with two keys: path and data. The path key points to a location relative to the request URL. The client should replace all of the data at that location in its cache with data.
            // patch:  The JSON-encoded data will be an object with two keys: path and data. The path key points to a location relative to the request URL. For each key in data, the client should replace the corresponding key in its cache with the data for that key in the message.
            // keep-alive:  The data for this event is null. No action is required.
            // cancel:  The data for this event is null. This event will be sent if the Security and Firebase Rules cause a read at the requested location to no longer be allowed.
            // auth_revoked:  The data for this event is a string indicating that a the credential has expired. This event will be sent when the supplied auth parameter is no longer valid.

            local eventLine = lines[0];
            local event = eventLine.slice(7).tolower();

            if(event == "keep-alive") continue;
            if(event == "cancel") {
                closeStream()
                //TODO: BUG: figure out what to do here
                _logError("Received a cancel event from the streaming API.  The Security and Firebase Rules cause a read at the requested location to no longer be allowed.")
                continue
            }
            if(event == "auth_revoked"){
                returns.push({"event": "auth_revoked"});
                continue
            }

            // get the data
            local dataLine = lines[1];
            local dataString = dataLine.slice(6);

            // pull interesting bits out of the data
            local d;
            try {
                d = _parseData(dataString, converter);
            } catch (e) {
                _logError("Exception while decoding (" + dataString.len() + " bytes): " + dataString);
                throw e;
            }

            if(event == "rules_debug"){ //This isn't documented by Firebase, but it is what happens if you stream with a debug JWT
                server.log(event + " - " + dataString)
                continue
            }

            //Should only be put or patch events

            // return a useful object
            returns.push({ "event": event, "path": d.path, "data": d.data });
        }

        return returns;
    }

    // Updates the local cache
    function _updateCache(message) {

        // base case - refresh everything
        if (message.event == "put" && message.path == "/") {
            _data = (message.data == null) ? {} : message.data;
            return _data
        }

        local pathParts = split(message.path, "/");
        local key = pathParts.len() > 0 ? pathParts[pathParts.len()-1] : null;

        local currentData = _data;
        local parent = _data;
        local lastPart = "";

        // Walk down the tree following the path
        foreach (part in pathParts) {
            if (typeof currentData != "array" && typeof currentData != "table") {
                // We have orphaned a branch of the tree
                if (lastPart == "") {
                    _data = {};
                    parent = _data;
                    currentData = _data;
                } else {
                    parent[lastPart] <- {};
                    currentData = parent[lastPart];
                }
            }

            parent = currentData;

            // NOTE: This is a hack to deal with a quirk of Firebase
            // Firebase sends arrays when the indicies are integers and its more efficient to use an array.
            if (typeof currentData == "array") {
                part = part.tointeger();
            }

            if (!(part in currentData)) {
                // This is a new branch
                currentData[part] <- {};
            }
            currentData = currentData[part];
            lastPart = part;
        }

        // Make the changes to the found branch
        if (message.event == "put") {
            if (message.data == null) {
                // Delete the branch
                if (key == null) {
                    _data = {};
                } else {
                    if (typeof parent == "array") {
                        parent[key.tointeger()] = null;
                    } else {
                        delete parent[key];
                    }
                }
            } else {
                // Replace the branch
                if (key == null) {
                    _data = message.data;
                } else {
                    if (typeof parent == "array") {
                        parent[key.tointeger()] = message.data;
                    } else {
                        parent[key] <- message.data;
                    }
                }
            }
        } else if (message.event == "patch") {
            foreach(k,v in message.data) {
                if (key == null) {
                    // Patch the root branch
                    _data[k] <- v;
                } else {
                    // Patch the current branch
                    parent[key][k] <- v;
                }
            }
        }

        // Now clean up the tree, removing any orphans
        _cleanTree(_data);
    }

    // Cleans the tree by deleting any empty nodes
    function _cleanTree(branch) {
        foreach (k,subbranch in branch) {
            if (typeof subbranch == "array" || typeof subbranch == "table") {
                _cleanTree(subbranch)
                if (subbranch.len() == 0) delete branch[k];
            }
        }
    }

    // Steps through a path to get the contents of the table at that point
    function _getDataFromPath(c_path, m_path, m_data) {

        // Make sure we are on the right branch
        if (m_path.len() > c_path.len() && m_path.find(c_path) != 0) return null;

        // Walk to the base of the callback path
        local new_data = m_data;
        foreach (step in split(c_path, "/")) {
            if (step == "") continue;
            if (step in new_data) {
                new_data = new_data[step];
            } else {
                new_data = null;
                break;
            }
        }

        // Find the data at the modified branch but only one step deep at max
        local changed_data = new_data;
        if (m_path.len() > c_path.len()) {
            // Only a subbranch has changed, pick the subbranch that has changed
            local new_m_path = m_path.slice(c_path.len())
            foreach (step in split(new_m_path, "/")) {
                if (step == "") continue;
                if (step in changed_data) {
                    changed_data = changed_data[step];
                } else {
                    changed_data = null;
                }
                break;
            }
        }

        return changed_data;
    }

    function _logError(message) {
        if (_debug) server.error(message);
    }

    function _irand(max) {
      // Generate a pseudo-random integer between 0 and max
      local roll = (1.0 * math.rand() / RAND_MAX) * (max + 1);
      return roll.tointeger();
    }

    function beforeSend(cb = null) {
      this._beforeSend = cb;
    }

    function beforeDataReceived(cb = null) {
      this._beforeDataReceived = cb;
    }

    // return a Promise if the Promise library is included
    function _returnPromise (request, reqTable=null, converter=null){
        if (_promiseIncluded) {

            if (_beforeSend) {
              local fail;
              local error;

              _beforeSend(reqTable, function/*auto-fail*/(err=null){
                fail = true;
                error = err ? err : FIREBASE_AUTO_FAIL_DEFAULT_ERROR;
              });

              if (fail == true) {
                return Promise.reject({"request": reqTable, "err": error})
              }
            }

            return Promise(function (resolve,reject){
                    local reqWithTimeout = httpRequestWithTimeout(request, 10.0)
                    reqWithTimeout.sendasync(function(res){

                        if (_beforeDataReceived) {
                          _beforeDataReceived(reqTable, res);
                        }

                        local data = res.body ;
                        if (typeof data == TYPE_STRING && data == "") {
                          if ((200 <= res.statuscode && res.statuscode < 300) || res.statuscode == 18) resolve(data); //NOTE: Assume that res.statuscode == 18 is success
                          else reject({"request": reqTable, "err": "Response was empty ("+res.statuscode+")"});
                        } else {
                          try { //wrap the _parse in a try/catch becuase sometimes it's not valid JSON
                            data = _parseData(res.body,converter);
                            if ((200 <= res.statuscode && res.statuscode < 300) || res.statuscode == 18) resolve(data); //NOTE: Assume that res.statuscode == 18 is success
                            else reject({"request": reqTable, "err": data.error});
                          } catch (err) {
                            server.error("In Firebase._returnPromise catch due to error: "+err)
                            server.error("typeof res.body == "+typeof res.body+" -- res.body: "+res.body);
                            if (typeof res.body == "string" || typeof res.body == "array" || typeof res.body == "table") server.error("res.body.len() == "+res.body.len());
                            reject ({"request": reqTable, "err": err});
                          }
                        }
                    }.bindenv(this));
            }.bindenv(this))
        }
        return;
    }

    // process the http response accordingly
    function _processResponse (request,callback,converter=null) {
        request.sendasync(function(res) {
            local data = res.body ;
            try {
                data = _parseData(data,converter);
                if (200 <= res.statuscode && res.statuscode < 300) {
                    callback(null,data);
                } else {
                    callback(data.error,null);
                }
            } catch (err) {
                callback(err,null);
            }
        }.bindenv(this))
    }

    // encode the data to send to firebase
    function _encodeData (data) {
      if (_jsonEncoderIncluded) return JSONEncoder.encode(data);
      else return http.jsonencode(data);
    }

    function _parseData (data,converter=null) {
      if (_jsonParserIncluded && converter != null) return JSONParser.parse(data,converter);
      else return http.jsondecode(data);
    }

}

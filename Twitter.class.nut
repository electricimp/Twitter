// Copyright (c) 2015 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

class Twitter {

    static version = [1,2,1];

    // URLs
    static STREAM_URL = "https://stream.twitter.com/1.1/";
    static TWEET_URL = "https://api.twitter.com/1.1/statuses/update.json";

    // OAuth
    _oauthTable =  null;

    _consumerKey = null;
    _consumerSecret = null;
    _accessToken = null;
    _accessSecret = null;

    // Streaming
    _streamingRequest = null;
    _reconnectTimeout = null;
    _buffer = null;

    // Debug Flag
    _debug = null;

    constructor (consumerKey, consumerSecret, accessToken, accessSecret, debug = true) {
        _consumerKey = consumerKey;
        _consumerSecret = consumerSecret;
        _accessToken = accessToken;
        _accessSecret = accessSecret;

        _oauthTable = {
            oauth_consumer_key = _consumerKey,
            oauth_nonce = null,
            oauth_signature_method = "HMAC-SHA1",
            oauth_timestamp = null,
            oauth_token = _accessToken,
            oauth_version = "1.0"
        };

        _reconnectTimeout = 60;
        _buffer = "";

        _debug = debug;
    }

    /***************************************************************************
    * function: Tweet
    *     Posts a tweet to the user's timeline
    *
    * Params:
    *     status - the tweet
    *     cb - an optional callback
    *
    * Return:
    *     bool indicating whether the tweet was successful(if no cb was supplied)
    *     nothing(if a callback was supplied)
    **************************************************************************/
    function tweet(status, cb = null) {
        // check if we got a string, instead of a table table
        if (typeof status == "string") {
            status = { "status": status };
        }

        local request = _oAuth1Request(TWEET_URL, status);

        if (cb == null) {
            local response = request.sendsync();
            if (response && response.statuscode != 200) {
                _error(format("Error updating_status tweet. HTTP Status Code %i:\r\n%s", response.statuscode, response.body));
                return false;
            } else {
                return true;
            }
        } else {
            request.sendasync(cb);
        }
    }

    /***************************************************************************
    * function: Stream
    *     Opens a connection to twitter's streaming API
    *
    * Params:
    *     searchTerms - what we're searching for
    *     onTweet - callback function that executes whenever there is data
    *     onError - callback function that executes whenever there is an error
    **************************************************************************/
    function stream(searchTerms, onTweet, onError = null) {
        _log("Opening stream for: " + searchTerms);

        local method = "statuses/filter.json"
        local post = { track = searchTerms };

        _streamingRequest = _oAuth1Request(STREAM_URL + method, post);

        _streamingRequest.sendasync(
            _onResponseFactory(searchTerms, onTweet, onError),
            _onDataFactory(searchTerms, onTweet, onError),
            NO_TIMEOUT
        );
    }

    // Closes the stream (if it's open)
    function closeStream() {
        if (_streamingRequest != null) {
            _streamingRequest.cancel();
            _streamingRequest = null;
        }
    }

    //-------------------- PRIVATE METHODS --------------------//
    // Build a onResponse callback for streaming requests
    function _onResponseFactory(searchTerms, onTweet, onError) {
        return function(resp) {
            if (resp.statuscode == 23 || resp.statuscode == 28 || resp.statuscode == 200) {
                // Expected status code
                // Note '23' accompanies an over-large anomalous data block from Twitter
                // Try again immediatly:
                imp.wakeup(0, function() { stream(searchTerms, onTweet, onError); }.bindenv(this));
            } else if (onError != null) {
                // Unexpected status code, but we have an error handler
                // Invoke the error handler
                imp.wakeup(0, function() { onError({ message = resp.body, code = resp.statuscode }); });
            } else if (resp.statuscode == 420 || resp.statuscode == 429) {
                // Too many requests
                // Try again with the _reconnectTimeout
                imp.wakeup(_reconnectTimeout, function() { stream(searchTerms, onTweet, onError); }.bindenv(this));
                _reconnectTimeout *= 2;
            } else if (resp.statuscode == 401) {
                // Unauthorized
                // Log a message (don't reopen the stream)
                _error("Failed to open stream (Unauthorized)");
            } else {
                // Unknown status code + no onError handler
                // log mesage and retry immediatly
                _log("Stream closed, retrying in 10 seconds (" + resp.statuscode + ": " + resp.body +")");
                imp.wakeup(10, function() { stream(searchTerms, onTweet, onError); }.bindenv(this));
            }
        }.bindenv(this);
    }

    // Builds an onData callback for streaming methods
    function _onDataFactory(searchTerms, onTweet, onError) {
        return function(body) {
            try {
                if (body.len() == 2) {
                    _reconnectTimeout = 60;
                    _buffer = "";
                    return;
                }

                local data = null;
                try {
                    // Try decoding the data
                    data = http.jsondecode(body);
                } catch(ex) {
                    // If it failed, add it to the buffer and try again
                    _buffer += body;
                    try {
                        data = http.jsondecode(_buffer);
                    } catch (ex) {
                        // If it failed a second time, we're done..
                        // (we'll try again next time we get data)
                        return;
                    }
                }

                // If we don't have valid data, we're done
                if (data == null) return;

                // If we do have valid data, clear the buffer and process data
                _buffer = "";

                // If there were errors
                if ("errors" in data) {
                    if (onError == null && this._debug) {
                        _defaultErrorHandler(data.errors);
                    } else if (onError != null) {
                        // Invoke the onError handler if it exists
                        imp.wakeup(0, function() { onError(data.errors); });
                    }
                    return;
                }

                // If it looks like a valid tweet, invoke the onTweet handler
                if (_looksLikeATweet(data)) {
                    imp.wakeup(0, function() { onTweet(data); });
                    return;
                }
            } catch(ex) {
                if (onError == null && this._debug) {
                    _defaultErrorHandler(data.errors);
                } else if (onError != null) {
                    imp.wakeup(0, function() { onError([{ message = "Squirrel Error - " + ex, code = -1 }]); });
                }

                // if an error occured, invoke error handler
                imp.wakeup(0, function() { onError([{ message = "Squirrel Error - " + ex, code = -1 }]); });
            }
        }.bindenv(this);
    }

    // Constructs a properly formated OAuth request
    function _oAuth1Request(postUrl, data) {
        local time = time();
        local nonce = time;

        _oauthTable.oauth_nonce = nonce;
        _oauthTable.oauth_timestamp = time;

        local keys = [];
        foreach (k,v in _oauthTable){
            keys.append(k);
        }

        foreach (k,v in data){
            keys.append(k);
        }

        keys.sort();

        local parm_string = "";
        foreach(k in keys){
            if (k in _oauthTable) {
                parm_string += "&" + http.urlencode({ [k] = _oauthTable[k] });
            } else if (k in data) {
                parm_string += "&" + http.urlencode({ [k] = data[k] });
            } else {
                _error("Unknown key in _oAuth1Request");
            }
        }

        //Drop the leading &
        parm_string = parm_string.slice(1);

        local signature_string = "POST&" + _encode(postUrl) + "&" + _encode(parm_string);

        local key = format("%s&%s", _encode(_consumerSecret), _encode(_accessSecret));
        local sha1 = _encode(http.base64encode(http.hash.hmacsha1(signature_string, key)));

        local auth_header = "oauth_consumer_key=\""+_consumerKey+"\", ";
        auth_header += "oauth_nonce=\""+nonce+"\", ";
        auth_header += "oauth_signature=\""+sha1+"\", ";
        auth_header += "oauth_signature_method=\""+"HMAC-SHA1"+"\", ";
        auth_header += "oauth_timestamp=\""+time+"\", ";
        auth_header += "oauth_token=\""+_accessToken+"\", ";
        auth_header += "oauth_version=\"1.0\"";

        local headers = { "Authorization": "OAuth " + auth_header };

        local url = postUrl + "?" + http.urlencode(data);
        local request = http.post(url, headers, "");
        return request;
    }

    // URL encodes a string
    function _encode(str) {
        return http.urlencode({ s = str }).slice(2);
    }

    // Looks for some key fields to identify a valid tweet
    function _looksLikeATweet(data) {
        return (
            "created_at" in data &&
            "id" in data &&
            "text" in data &&
            "user" in data
        );
    }

    // Logs each error message
    function _defaultErrorHandler(errors) {
        foreach(error in errors) {
            _error(error.code + ": " + error.message);
        }
    }

    // Logs a message when the debug flag is set
    function _log(msg) {
        if (_debug) server.log(msg)
    }

    // Logs an error message when the debug flag is set
    function _error(msg) {
        if (_debug) server.error(msg);
    }
}

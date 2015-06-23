// Copyright (c) 2015 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

class Twitter {

    static version = [1,2,0];

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
            function(resp) {
                // connection timeout
                _log("Stream Closed (" + resp.statuscode + ": " + resp.body +")");

                if (resp.statuscode == 420) {
                    // 420 - Enhance your calm (too many requests)
                    // Try again with the _reconnectTimeout
                    imp.wakeup(_reconnectTimeout, function() { stream(searchTerms, onTweet, onError); }.bindenv(this));
                    _reconnectTimeout *= 2;
                } else if (resp.statuscode == 28 || resp.statuscode == 200 || onError == null) {
                    // Expected statuscode (28 = curl timeout, or 200, OK) or no error handler:
                    // Try again immediatly
                    imp.wakeup(0, function() { stream(searchTerms, onTweet, onError); }.bindenv(this));
                } else {
                    // Unexpected status code, but we have an error handler
                    imp.wakeup(0, function() { onError([{ message = resp.body, code = resp.statuscode }]); });
                }
            }.bindenv(this),

            function(body) {
                try {
                    if (body.len() == 2) {
                        _reconnectTimeout = 60;
                        _buffer = "";
                        return;
                    }

                    local data = null;
                    try {
                        data = http.jsondecode(body);
                    } catch(ex) {
                        _buffer += body;
                        try {
                            data = http.jsondecode(_buffer);
                        } catch (ex) {
                            return;
                        }
                    }

                    if (data == null) return;

                    // we have a complete tweet at this point
                    // so clear out the buffer
                    _buffer = "";

                    if ("errors" in data) {
                        _error("Got an error");
                        if (onError == null && this._debug) {
                            _defaultErrorHandler(data.errors);
                        } else if (onError != null) {
                            imp.wakeup(0, function() { onError(data.errors); });
                        }
                        return;
                    }
                    else {
                        if (_looksLikeATweet(data)) {
                            imp.wakeup(0, function() { onTweet(data); });
                            return;
                        }
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
            }.bindenv(this)
        );
    }

    // Closes the stream (if it is open)
    function closeStream() {
        if (_streamingRequest != null) {
            this._streamingRequest.cancel();
            this._streamingRequest = null;
        }
    }

    /***** Private Function - Do Not Call *****/

    function _encode(str) {
        return http.urlencode({ s = str }).slice(2);
    }

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

    function _looksLikeATweet(data) {
        return (
            "created_at" in data &&
            "id" in data &&
            "text" in data &&
            "user" in data
        );
    }

    function _defaultErrorHandler(errors) {
        foreach(error in errors) {
            _error(error.code + ": " + error.message);
        }
    }

    function _log(msg) {
        if (_debug) server.log(msg)
    }

    function _error(msg) {
        if (_debug) server.error(msg);
    }
}

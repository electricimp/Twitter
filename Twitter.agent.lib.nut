// MIT License
//
// Copyright 2015-2016 Electric Imp
//
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO
// EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES
// OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.


const TWITTER_DEFAULT_RECONNECT_TIMEOUT_SEC = 60;

class Twitter {

    static VERSION = "2.0.0";

    // URLs
    static STREAM_URL = "https://stream.twitter.com/1.1/";
    static TWEET_URL  = "https://api.twitter.com/1.1/statuses/update.json";

    // Generic
    _buffer = null;
    _debug  = null;

    // OAuth
    _oauthConfig      = null;

    _consumerKey      = null;
    _consumerSecret   = null;
    _accessToken      = null;
    _accessSecret     = null;

    // Streaming
    _streamingRequest = null;
    _reconnectTimeout = null;
    _reconnectTimer   = null;

    constructor (consumerKey, consumerSecret, accessToken, accessSecret, debug = true) {
        _consumerKey    = consumerKey;
        _consumerSecret = consumerSecret;
        _accessToken    = accessToken;
        _accessSecret   = accessSecret;

        _oauthConfig = {
            "oauth_version"          : "1.0",
            "oauth_consumer_key"     : _consumerKey,
            "oauth_token"            : _accessToken,
            "oauth_signature_method" : "HMAC-SHA1",
            "oauth_timestamp"        : null,
            "oauth_nonce"            : null
        };

        _reconnectTimeout = TWITTER_DEFAULT_RECONNECT_TIMEOUT_SEC; // sec
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
        _reconnectTimeout = TWITTER_DEFAULT_RECONNECT_TIMEOUT_SEC;
        if (_reconnectTimer) {
            imp.cancelwakeup(_reconnectTimer);
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
                _reconnectTimer = imp.wakeup(0,
                    function() {
                        stream(searchTerms, onTweet, onError);
                    }.bindenv(this)
                );
            } else if (resp.statuscode == 420 || resp.statuscode == 429) {
                // Too many requests
                // Try again with the _reconnectTimeout
                _reconnectTimer = imp.wakeup(_reconnectTimeout,
                    function() {
                        stream(searchTerms, onTweet, onError);
                    }.bindenv(this)
                );
                _reconnectTimeout += TWITTER_DEFAULT_RECONNECT_TIMEOUT_SEC;
            } else if (resp.statuscode == 401) {
                // Unauthorized
                // Log a message (don't reopen the stream)
                _error("Failed to open stream (Unauthorized)");
            } else if (onError != null) {
                // Unexpected status code, but we have an error handler
                // Invoke the error handler
                _reconnectTimer = imp.wakeup(0,
                    function() {
                        onError({ "message" : resp.body, "code" : resp.statuscode });
                    }.bindenv(this)
                );
            } else {
                // Unknown status code + no onError handler
                // log mesage and retry immediatly
                _log("Stream closed, retrying in 10 seconds (" + resp.statuscode + ": " + resp.body +")");
                _reconnectTimer = imp.wakeup(10,
                    function() {
                        stream(searchTerms, onTweet, onError);
                    }.bindenv(this)
                );
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

                _buffer += body;
                while (1) {
                    // Run through the contents of _buffer looking for message blocks,
                    // delimited by \r\n. For each block found, remove it from _buffer
                    local p = _buffer.find("\r\n");
                    if (p == null) break;
                    local message = _buffer.slice(0, p);
                    _buffer = _buffer.slice(p + 2);
                    local data = null;

                    // Try to decode the extracted message block as JSON
                    try {
                        data = http.jsondecode(message);
                    } catch (ex) {
                        continue;
                    }

                    // If the block has decoded successfully, check to see if it’s
                    // (a) an error message, then (b) a Tweet
                    if (data != null) {
                        // If there were errors
                        if ("errors" in data) {
                            if (onError == null && this._debug) {
                                _defaultErrorHandler(data.errors);
                            } else if (onError != null) {
                                // Invoke the onError handler if it exists
                                imp.wakeup(0, function() { onError(data.errors); });
                            }
                        }

                        // If it looks like a valid tweet, invoke the onTweet handler
                        if (_looksLikeATweet(data)) imp.wakeup(0, function() { onTweet(data); });
                    }
                }

               //_buffer = "";
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

        _oauthConfig.oauth_nonce = nonce;
        _oauthConfig.oauth_timestamp = time;

        local keys = [];
        foreach (k,v in _oauthConfig){
            keys.append(k);
        }

        foreach (k,v in data){
            keys.append(k);
        }

        keys.sort();

        local parm_string = "";
        foreach(k in keys){
            if (k in _oauthConfig) {
                parm_string += "&" + http.urlencode({ [k] = _oauthConfig[k] });
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

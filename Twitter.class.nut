// Copyright (c) 2015 Electric Imp
// This file is licensed under the MIT License
// http://opensource.org/licenses/MIT

class Twitter {
	// OAuth
	_consumerKey = null;
	_consumerSecret = null;
	_accessToken = null;
	_accessSecret = null;
  _oauthTable   = null;

	// URLs
	streamUrl = "https://stream.twitter.com/1.1/";
	tweetUrl = "https://api.twitter.com/1.1/statuses/update.json";

	// Streaming
	_streamingRequest = null;
	_reconnectTimeout = null;
	_buffer = null;

	// Debug Flag
	_debug = false;

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
	*   Posts a tweet to the user's timeline
	*
	* Params:
	*   status - the tweet
	*   cb - an optional callback
	*
	* Return:
	*   bool indicating whether the tweet was successful(if no cb was supplied)
	*   nothing(if a callback was supplied)
	**************************************************************************/

	function tweet(status, cb = null) {
		// check if we got a string, instead of a table table
		if (typeof status == "string") {
			status = { "status": status };
		}

		local request = _oAuth1Request(tweetUrl, status);

		if (cb == null) {
			local response = request.sendsync();
			if (response && response.statuscode != 200) {
				this._error(format("Error updating_status tweet. HTTP Status Code %i:\r\n%s", response.statuscode, response.body));
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
	*   Opens a connection to twitter's streaming API
	*
	* Params:
	*   searchTerms - what we're searching for
	*   onTweet - callback function that executes whenever there is data
	*   onError - callback function that executes whenever there is an error
	**************************************************************************/
	function stream(searchTerms, onTweet, onError = null) {
		this._log("Opening stream for: " + searchTerms);

		// Set default error handler

		if (onError == null) onError = _defaultErrorHandler.bindenv(this);

		local method = "statuses/filter.json"
		local post = { track = searchTerms };
		local request = _oAuth1Request(streamUrl + method, post);

		this._streamingRequest = request.sendasync(
			function(resp) {
				// connection timeout
				this._log("Stream Closed (" + resp.statuscode + ": " + resp.body +")");

				// if we have autoreconnect set
				if (resp.statuscode == 28 || resp.statuscode == 200) {
					stream(searchTerms, onTweet, onError);
				} else if (resp.statuscode == 420) {
					imp.wakeup(_reconnectTimeout, function() { stream(searchTerms, onTweet, onError); }.bindenv(this));
					_reconnectTimeout *= 2;
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

					// if it's an error

					if ("errors" in data) {
						this._error("Got an error");
						onError(data.errors);
						return;
					}
					else {
						if (_looksLikeATweet(data)) {
							onTweet(data);
							return;
						}
					}
				} catch(ex) {
					// if an error occured, invoke error handler

					onError([{ message = "Squirrel Error - " + ex, code = -1 }]);
				}
			}.bindenv(this)
		);
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
				this._error("Unknown key in _oAuth1Request");
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
			this._error("ERROR " + error.code + ": " + error.message);
		}
	}

	function _log(msg) {
		if (_debug) server.log(msg)
	}

	function _error(msg) {
		if (_debug) server.error(msg);
	}
}

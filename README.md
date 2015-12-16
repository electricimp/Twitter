# Twitter Class

The Twitter class allows you to Tweet and to stream results from Twitter’s streaming API.

**NOTE:** You can only have one instance of the streaming API open per Twitter account per Twitter App.

## Create a Twitter App

In order to use the Twitter API, you’ll first need to [create a Twitter App](https://apps.twitter.com/).

## Constructor(*apiKey, apiSecret, authToken, tokenSecret, [debug]*)

The Twitter constructor takes 4 parameters that constitute your Twitter app's OAuth credentials. You can find these in the *Keys and Access Tokens* section of your App in the Twitter Dev Center.

The constructor can also take an optional fifth parameter: a debugging flag (default value is true). When the debug flag is set to true, the Twitter class will log information to the device logs - when it is set to false it will not. It is typically recommended that you leave the flag set to true.

```squirrel
#require "Twitter.class.nut:1.2.1"
twitter <- Twitter(API_KEY, API_SECRET, AUTH_TOKEN, TOKEN_SECRET)
```

## tweet(*tweetData, [callback]*)

Sending a Tweet is incredibly simple, and can be done with the *tweet()* method. The first parameter, tweetData can be one of two things: a string representing the text of the tweet, or a table representing the tweet.

In most applications simply passing a string should be sufficient:

```squirrel
twitter.tweet("I just tweeted from an @electricimp agent - bit.ly/ei-twitter.")
```

By passing a table instead of a string, we can include additional Tweet fields such as geolocation, reply_to, etc. The table **must** include the key *status* which is the text of the tweet:

```squirrel
// reply to every tweet that mentions 'electricimp'
twitter.stream("electricimp", function(tweetData) {
    local tweetTable = {
      "in_reply_to_status_id": tweetData.id_str,
      "status": format("@%s Thanks for saying hello! (tweeted at %i)", tweetData.user.screen_name, time())
    };

    twitter.tweet(tweetTable);

});
```

## stream(*searchTerm, callback, [onError]*)

You can get near instantaneous results for a Twitter search by using the streaming API. To open a stream, you need to provide two values: a string containing the text you want to search for and a callback function that will be executed whenever a new Tweet comes into the stream. The callback takes a single parameter: a table into which the Tweet and associated data will be placed. The table has two keys: *text* (the text of the Tweet as a string) and *user* (a table containing information about the user who posted the Tweet).

```squirrel
function onTweet(tweetData) {
    // Log the Tweet, and who tweeted it (there is a LOT more info in tweetData)
    this.log(format("%s - %s", tweetData.text, tweetData.user.screen_name))
}

twitter.stream("searchTerm", onTweet)
```

An optional third parameter can be passed to *Twitter.stream()*: onError. The onError parameter is a callback method that takes a single parameter - *errors* - that will be invoked if any errors are encountered during the stream. The erors parameter is an array of error objects, each with the following keys: `{ "code": errorCode, "message": "description of the error" }``.

```squirrel
function onError(errors) {
    // log all the message
    foreach(err in errors) {
        server.error(err.code + ": " + err.message);
    }

    // close the stream, and re-open it
    twitter.closeStream();
    twitter.stream();
}

function onTweet(tweetData) {
  this.log(format("%s - %s", tweetData.text, tweetData.user.screen_name));
}

twitter.stream("searchTerm", onTweet, onError);
```

If the *onError* parameter is omitted, the Twitter class will automatically try to reopen the stream when an unexpected response is encounter. If the onError parameter is included, you are responsible for reopening the stream in the onError callback.

## closeStream()

The *closeStream* method will close the stream created by the *stream* method.

```squirrel
twitter.stream("iot", onTweet);

// Only stream data for 10 seconds
imp.wakeup(10, function() {
    twitter.closeStream();
});
```

## License

The Twitter library is licensed under the [MIT License](./LICENSE).

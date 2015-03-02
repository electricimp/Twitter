# Twitter Class

The Twitter class allows you to Tweet and to stream results from Twitter’s streaming API.

You can only have one instance of the streaming API open per Twitter account per app.

## Class Usage

### Create a Twitter App

In order to use the Twitter API, you’ll first need to [create a Twitter App](https://apps.twitter.com/).

### Constructor

You instantiate the class with the following line of code:

```squirrel
twitter <- Twitter(API_KEY, API_SECRET, AUTH_TOKEN, TOKEN_SECRET)
```

### Tweeting: tweet(*message*)

Sending a Tweet is simple: call the *tweet()* method. This takes a single parameter: a string containing the text of your Tweet.

```squirrel
twitter.tweet("I just tweeted from an @electricimp agent - bit.ly/ei-twitter.")
```

### Streaming: stream(*searchTerm*, *callback*)

You can get near instantaneous results for a Twitter search by using the streaming API. To open a stream, you need to provide two values: a string containing the text you want to search for and a callback function that will be executed whenever a new Tweet comes into the stream. The callback takes a single parameter: a table into which the Tweet and associated data will be placed. The table has two keys: *text* (the text of the Tweet as a string) and *user* (a table containing information about the user who posted the Tweet).

```squirrel
function onTweet(tweetData) 
{
    // Log the Tweet, and who tweeted it (there is a LOT more info in tweetData)
    
    server.log(format("%s - %s", tweetData.text, tweetData.user.screen_name))
}

twitter.stream("searchTerm", onTweet)
```

## License

This library is licensed under the [MIT License](./LICENSE).

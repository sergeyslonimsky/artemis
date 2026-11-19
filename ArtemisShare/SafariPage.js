// Runs in the page when Artemis is picked in Safari's share sheet: hands over the page's text,
// which the extension can't fetch on its own.
var SafariPage = function() {};

SafariPage.prototype = {
    run: function(args) {
        args.completionFunction({
            url: document.URL,
            title: document.title,
            text: document.body ? document.body.innerText : ""
        });
    },
    finalize: function(args) {}
};

var ExtensionPreprocessingJS = new SafariPage;

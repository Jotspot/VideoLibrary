// Manual search, appended to docs/manual/search.js after the topic list
// (window.MANUAL_TOPICS). On the index it lists matching topics in place of
// the cards; on a topic page it filters the sidebar. "/" focuses the box.
(function () {
  var topics = window.MANUAL_TOPICS || [];
  var input = document.querySelector('[data-manual-search]');
  if (!input) return;

  function score(topic, words) {
    var title = topic.title.toLowerCase(), summary = topic.summary.toLowerCase(), text = topic.text.toLowerCase();
    var total = 0;
    for (var i = 0; i < words.length; i++) {
      var word = words[i];
      if (title.indexOf(word) >= 0) total += 10;
      else if (summary.indexOf(word) >= 0) total += 4;
      else if (text.indexOf(word) >= 0) total += 1;
      else return 0;
    }
    return total;
  }

  function matches(query) {
    var words = query.toLowerCase().split(/\s+/).filter(Boolean);
    return topics
      .map(function (topic) { return { topic: topic, score: score(topic, words) }; })
      .filter(function (match) { return match.score > 0; })
      .sort(function (a, b) { return b.score - a.score; })
      .map(function (match) { return match.topic; });
  }

  // A short bit of the page around the first matching word.
  function snippet(topic, query) {
    var word = query.toLowerCase().split(/\s+/).filter(Boolean)[0] || '';
    var at = topic.text.toLowerCase().indexOf(word);
    if (!word || at < 0 || topic.title.toLowerCase().indexOf(word) >= 0) return topic.summary;
    var start = Math.max(0, at - 60);
    return (start > 0 ? '…' : '') + topic.text.slice(start, at + 110).trim() + '…';
  }

  function escape(text) {
    return text.replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  var results = document.querySelector('[data-manual-results]');
  var groups = document.querySelectorAll('[data-group]');
  var empty = document.querySelector('[data-manual-empty]');

  function update() {
    var query = input.value.trim();
    var found = query ? matches(query) : topics;
    if (results) {
      // Index page: results replace the grouped cards while searching.
      results.hidden = !query;
      groups.forEach(function (group) { group.hidden = !!query; });
      if (query) {
        results.innerHTML = found.length
          ? '<div class="mcards">' + found.map(function (topic) {
              return '<a class="mcard" href="/manual/' + topic.slug + '"><span class="mcard-icon"><svg class="i"><use href="#' + topic.icon + '"/></svg></span>'
                + '<span><span class="mcard-title">' + escape(topic.title) + '</span><span class="mcard-text">' + escape(snippet(topic, query)) + '</span></span></a>';
            }).join('') + '</div>'
          : '<p class="mresults-empty">Nothing in the manual matches “' + escape(query) + '”.</p>';
      }
      return;
    }
    // Topic page: filter the sidebar.
    var slugs = {};
    found.forEach(function (topic) { slugs[topic.slug] = true; });
    groups.forEach(function (group) {
      var shown = 0;
      group.querySelectorAll('a[data-slug]').forEach(function (link) {
        var keep = !query || slugs[link.dataset.slug];
        link.hidden = !keep;
        if (keep) shown++;
      });
      group.hidden = shown === 0;
    });
    if (empty) empty.hidden = !query || found.length > 0;
  }

  input.addEventListener('input', update);
  input.addEventListener('keydown', function (event) {
    if (event.key === 'Enter') {
      var first = input.value.trim() && matches(input.value.trim())[0];
      if (first) location.href = '/manual/' + first.slug;
    } else if (event.key === 'Escape') {
      input.value = '';
      update();
      input.blur();
    }
  });
  document.addEventListener('keydown', function (event) {
    var target = event.target;
    var typing = target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName));
    if (event.key === '/' && !typing && !event.metaKey && !event.ctrlKey && !event.altKey) {
      event.preventDefault();
      input.focus();
    }
  });
})();

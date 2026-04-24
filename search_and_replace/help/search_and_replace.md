# search_and_replace

Commands:

* `find_in_file`: open the search form for the current file.
* `find_accross_files`: open the search form for a file pattern.

Search form:

* `Search:` search text.
* `Regex:` `0` or `1`. Press `Space` on this line to toggle it.
* `File pattern:` shown only for `find_accross_files`.

Keys:

* `Enter`: launch `rgr` fullscreen.
* `Tab`: move to the next field.
* `Up` / `Down`: move between fields.
* `Escape`: close the form.

UI:

* uses micro's real popup prompt, not a split pane.

Command shape:

* `rgr -C 3 --context-separator=--- SEARCH_KEY`
* adds `-F` when regex is off
* adds either the current file path or `-g FILE_PATTERN`

Before and after:

* saves the current file before launching `rgr`
* reloads all clean disk-backed open buffers after `rgr` exits
* skips modified buffers to avoid discarding unsaved edits

Requirements:

* `rgr` must be available.

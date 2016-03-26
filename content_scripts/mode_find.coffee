# NOTE(smblott).  Ultimately, all of the FindMode-related code should be moved here.

# This prevents unmapped printable characters from being passed through to underlying page; see #1415.  Only
# used by PostFindMode, below.
class SuppressPrintable extends Mode
  constructor: (options) ->
    super options
    handler = (event) => if KeyboardUtils.isPrintable event then @suppressEvent else @continueBubbling
    type = document.getSelection().type

    # We use unshift here, so we see events after normal mode, so we only see unmapped keys.
    @unshift
      _name: "mode-#{@id}/suppress-printable"
      keydown: handler
      keypress: handler
      keyup: (event) =>
        # If the selection type has changed (usually, no longer "Range"), then the user is interacting with
        # the input element, so we get out of the way.  See discussion of option 5c from #1415.
        if document.getSelection().type != type then @exit() else handler event

# When we use find, the selection/focus can land in a focusable/editable element.  In this situation, special
# considerations apply.  We implement three special cases:
#   1. Disable insert mode, because the user hasn't asked to enter insert mode.  We do this by using
#      InsertMode.suppressEvent.
#   2. Prevent unmapped printable keyboard events from propagating to the page; see #1415.  We do this by
#      inheriting from SuppressPrintable.
#   3. If the very-next keystroke is Escape, then drop immediately into insert mode.
#
class PostFindMode extends SuppressPrintable
  constructor: ->
    return unless document.activeElement and DomUtils.isEditable document.activeElement
    element = document.activeElement

    super
      name: "post-find"
      # PostFindMode shares a singleton with focusInput; each displaces the other.
      singleton: "post-find-mode/focus-input"
      exitOnBlur: element
      exitOnClick: true
      keydown: (event) -> InsertMode.suppressEvent event # Always truthy, so always continues bubbling.
      keypress: (event) -> InsertMode.suppressEvent event
      keyup: (event) -> InsertMode.suppressEvent event

    # If the very-next keydown is Escape, then exit immediately, thereby passing subsequent keys to the
    # underlying insert-mode instance.
    @push
      _name: "mode-#{@id}/handle-escape"
      keydown: (event) =>
        if KeyboardUtils.isEscape event
          DomUtils.suppressKeyupAfterEscape handlerStack
          @exit()
          @suppressEvent
        else
          handlerStack.remove()
          @continueBubbling

class FindMode extends Mode
  @query:
    rawQuery: ""
    matchCount: 0
    hasResults: false

  constructor: (options = {}) ->
    # Save the selection, so findInPlace can restore it.
    @initialRange = getCurrentRange()
    FindMode.query = rawQuery: ""
    if options.returnToViewport
      @scrollX = window.scrollX
      @scrollY = window.scrollY
    super extend options,
      name: "find"
      indicator: false
      exitOnClick: true

    HUD.showFindMode this

  exit: (event) ->
    super()
    handleEscapeForFindMode() if event

  restoreSelection: ->
    range = @initialRange
    selection = getSelection()
    selection.removeAllRanges()
    selection.addRange range

  findInPlace: (query) ->
    # If requested, restore the scroll position (so that failed searches leave the scroll position unchanged).
    @checkReturnToViewPort()
    FindMode.updateQuery query
    # Restore the selection.  That way, we're always searching forward from the same place, so we find the right
    # match as the user adds matching characters, or removes previously-matched characters. See #1434.
    @restoreSelection()
    query = if FindMode.query.isRegex then FindMode.getNextQueryFromRegexMatches(0) else FindMode.query.parsedQuery
    FindMode.query.hasResults = FindMode.execute query

  @updateQuery: (query) ->
    @query.rawQuery = query
    # the query can be treated differently (e.g. as a plain string versus regex depending on the presence of
    # escape sequences. '\' is the escape character and needs to be escaped itself to be used as a normal
    # character. here we grep for the relevant escape sequences.
    @query.isRegex = Settings.get 'regexFindMode'
    hasNoIgnoreCaseFlag = false
    @query.parsedQuery = @query.rawQuery.replace /(\\{1,2})([rRI]?)/g, (match, slashes, flag) =>
      return match if flag == "" or slashes.length != 1
      switch (flag)
        when "r"
          @query.isRegex = true
        when "R"
          @query.isRegex = false
        when "I"
          hasNoIgnoreCaseFlag = true
      ""

    # default to 'smartcase' mode, unless noIgnoreCase is explicitly specified
    @query.ignoreCase = !hasNoIgnoreCaseFlag && !Utils.hasUpperCase(@query.parsedQuery)

    regexPattern = if @query.isRegex
      @query.parsedQuery
    else
      Utils.escapeRegexSpecialCharacters @query.parsedQuery

    # If we are dealing with a regex, grep for all matches in the text, and then call window.find() on them
    # sequentially so the browser handles the scrolling / text selection.
    # If we are doing a basic plain string match, we still want to grep for matches of the string, so we can
    # show a the number of results.
    try
      pattern = new RegExp regexPattern, "g#{if @query.ignoreCase then "i" else ""}"
    catch error
      return # If we catch a SyntaxError, assume the user is not done typing yet and return quietly.

    # innerText will not return the text of hidden elements, and strip out tags while preserving newlines.
    # NOTE(mrmr1993): innerText doesn't include the text contents of <input>s and <textarea>s. See #1118.
    text = document.body.innerText
    regexMatches = text.match pattern
    @query.regexMatches = regexMatches if @query.isRegex
    @query.activeRegexIndex = 0 if @query.isRegex
    @query.matchCount = regexMatches?.length

  @getNextQueryFromRegexMatches: (stepSize) ->
    # find()ing an empty query always returns false
    return "" unless @query.regexMatches

    totalMatches = @query.regexMatches.length
    @query.activeRegexIndex += stepSize + totalMatches
    @query.activeRegexIndex %= totalMatches

    @query.regexMatches[@query.activeRegexIndex]

  @getQuery: (backwards) ->
    # check if the query has been changed by a script in another frame
    mostRecentQuery = FindModeHistory.getQuery()
    if (mostRecentQuery != @query.rawQuery)
      @updateQuery mostRecentQuery

    if @query.isRegex
      @getNextQueryFromRegexMatches(if backwards then -1 else 1)
    else
      @query.parsedQuery

  @saveQuery: -> FindModeHistory.saveQuery @query.rawQuery

  # :options is an optional dict. valid parameters are 'caseSensitive' and 'backwards'.
  @execute: (query, options) ->
    result = null
    options = extend {
      backwards: false
      caseSensitive: !@query.ignoreCase
      colorSelection: true
    }, options
    query ?= FindMode.getQuery options.backwards

    if options.colorSelection
      document.body.classList.add("vimiumFindMode")
      # ignore the selectionchange event generated by find()
      document.removeEventListener("selectionchange", @restoreDefaultSelectionHighlight, true)

    result = window.find(query, options.caseSensitive, options.backwards, true, false, true, false)

    if options.colorSelection
      setTimeout(
        -> document.addEventListener("selectionchange", @restoreDefaultSelectionHighlight, true)
      , 0)

    # We are either in normal mode ("n"), or find mode ("/").  We are not in insert mode.  Nevertheless, if a
    # previous find landed in an editable element, then that element may still be activated.  In this case, we
    # don't want to leave it behind (see #1412).
    if document.activeElement and DomUtils.isEditable document.activeElement
      document.activeElement.blur() unless DomUtils.isSelected document.activeElement

    result

  @restoreDefaultSelectionHighlight: -> document.body.classList.remove("vimiumFindMode")

  checkReturnToViewPort: ->
    window.scrollTo @scrollX, @scrollY if @options.returnToViewport

getCurrentRange = ->
  selection = getSelection()
  if selection.type == "None"
    range = document.createRange()
    range.setStart document.body, 0
    range.setEnd document.body, 0
    range
  else
    selection.collapseToStart() if selection.type == "Range"
    selection.getRangeAt 0

root = exports ? window
root.PostFindMode = PostFindMode
root.FindMode = FindMode

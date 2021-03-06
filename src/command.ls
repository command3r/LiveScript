# The `LiveScript` utility.

{argv} = process

global import
  LiveScript : require \./livescript
  fs   : require \fs
  path : require \path
  util : require \util
  say  : !-> process.stdout.write it + \\n
  warn : !-> process.stderr.write it + \\n
  die  : !-> warn it; process.exit 1
  p    : !-> []forEach.call @@, console.dir
  pp   : !(x, showHidden, depth) ->
    say util.inspect x, showHidden, depth, !process.env.NODE_DISABLE_COLORS
  ppp  : !-> pp it, true, null

# Use the [option parser](#optparse).
{$args} = o = require(\./optparse) do
  interactive : 'start REPL; use ^J for multiline input'
  compile     : 'compile to JavaScript and save as .js files'
  output      :['compile into the specified directory' \DIR]
  watch       : 'watch scripts for changes, and repeat'
  stdin       : 'read stdin'
  eval        : 'read command line arguments as script'
  require     :['require libraries before executing' \FILE+]
  bare        : 'compile without the top-level function wrapper'
  print       : 'print the result to stdout'
  lex         : 'print the tokens the lexer produces'
  tokens      : 'print the tokens the rewriter produces'
  ast         : 'print the syntax tree the parser produces'
  json        : 'print/compile as JSON'
  nodejs      :['pass options through to the "node" binary' \ARGS+]
  version     : 'display version'
  help        : 'display this'

die "Unrecognized option(s): #that\n\n#{help!}" if o.$unknowns * ' '

switch
| o.nodejs  => forkNode!
| o.version => say version!
| o.help    => say help!
| otherwise =>
  o.run = not o.compile ||= o.output
  process.execPath = argv.0 = argv.1
  argv.splice 2 9e9
  argv.push ...if o.stdin then $args else
    if o.run then $args.splice 1 9e9 else []
  if o.require
    ({filename} = module)filename = \.
    that.forEach require
    module <<< {filename}
  switch
  case o.eval
    argv.1 = \eval
    compileScript '' $args * \\n
  case o.stdin                then compileStdin!
  case $args.length           then compileScripts!
  case process.stdin.readable then compileStdin!
  default
    o.interactive or say version! + \\n + help! + \\n
    repl!

# Calls a `fs` method, exiting on error.
!function fshoot name, arg, callback
  e, result <-! fs[name] arg
  die e.stack || e if e
  callback result

# Asynchronously read in each LiveScript script in a list of source files and
# compile them. If a directory is passed, recursively compile all
# _.ls_ files in it and all subdirectories.
!function compileScripts
  $args.forEach !-> walk it, , true
  !function walk source, base ? path.normalize(source), top
    !function work
      fshoot \readFile source, !-> compileScript source, "#it", base
    e, stats <-! fs.stat source
    if e
      return walk "#source.ls" if top
      die e
    if stats.isDirectory!
      <-! fshoot \readdir source
      <-! it.forEach
      walk path.join(source, it), base
    else if top or path.extname(source)toLowerCase! is \.ls
      if o.watch then watch source, work else work!

# Compile a single source script, containing the given code, according to the
# requested options.
!function compileScript filename, input, base
  options = {filename, o.bare}
  t       = {input, options}
  try
    LiveScript.emit \lex t
    t.tokens = LiveScript.tokens t.input, raw: o.lex
    if o.lex or o.tokens
      printTokens t.tokens
      throw
    LiveScript.emit \parse t
    t.ast = LiveScript.ast t.tokens
    if o.ast
      say if o.json then t.ast.stringify 2 else ''trim.call t.ast
      throw
    LiveScript.emit \compile t
    options.bare ||= o.json or o.run
    t.ast.makeReturn! if o.json or o.run and o.print
    t.output = t.ast.compileRoot options
    if o.json or o.run
      LiveScript.emit \run t
      t.result = LiveScript.run t.output, options, true
    if o.json
      t.output = JSON.stringify(t.result, null, 2) + \\n
    if o.run
      switch
      | o.json  => process.stdout.write t.output
      | o.print => console.log t.result
      throw
    LiveScript.emit \write t
    if o.print or not filename
    then say t.output.trimRight!
    else writeJS filename, t.output, base
  catch if e?
    if LiveScript.listeners(\failure)length
      LiveScript.emit \failure e, t
    else
      warn "Failed at: #filename" if filename
      unless e instanceof SyntaxError or /^Parse error /test e.message
        e = e.stack or e
      if o.watch then warn e + \\7
                 else die  e
    return
  LiveScript.emit \success t

# Attach the appropriate listeners to compile scripts incoming over **stdin**.
!function compileStdin
  argv.1 = \stdin
  with process.openStdin!
    code = ''
    @on \data !-> code += it
    @on \end  !-> compileScript '' code

# Watch a source LiveScript file using `setTimeout`, taking an `action` every
# time the file is updated.
!function watch source, action
  :repeat let ptime = 0
    {mtime} <-! fshoot \stat source
    do action if ptime ^^^ mtime
    setTimeout repeat, 500ms, mtime

# Write out a JavaScript source file with the compiled code. By default, files
# are written out in `cwd` as `.js` files with the same name, but the output
# directory can be customized with `--output`.
!function writeJS source, js, base
  #     foo.ls     => foo.js
  #     foo.jsm.ls => foo.jsm
  filename = path.basename(source)replace do
    /(?:(\.\w+)?\.\w+)?$/ -> @@1 or if o.json then \.json else \.js
  dir = path.dirname source
  if o.output
    dir = path.join that, dir.slice if base is \. then 0 else base.length
  jsPath = path.join dir, filename
  !function compile
    e <-! fs.writeFile jsPath, js || \\n
    return warn e if e
    util.log "#source => #jsPath" if o.watch
  e <-! fs.stat dir
  return compile! unless e
  require \child_process .exec do
    "mkdir #{[\-p unless /^win/test process.platform]} #dir" compile

# Pretty-print a stream of tokens.
!function printTokens tokens
  lines = []
  for [tag, val, lno] in tokens
    lines@@[lno]push if tag.toLowerCase! is val then tag else "#tag:#val"
  for l in lines then say(if l then l.join(' ')replace /\n/g \\\n else '') 

# A Read-Eval-Print-Loop.
# Good for simple tests or poking around the
# [**node.js** API](http://nodejs.org/api/).
#
# - __^M__: Compile input, and prints (if _--compile_) or evaluates it.
# - __^J__: Insert linefeed.
# - __^C__: Cancel input if any. Quit otherwise.
# - __??__: <https://github.com/joyent/node/blob/master/lib/readline.js>
!function repl
  argv.1 = \repl
  # ref. <https://github.com/joyent/node/blob/master/lib/repl.js>
  # repl.infunc = false unless repl.infunc?
  code  = if repl.infunc then '  ' else ''
  cont  = false
  readline  = require(\readline)createInterface process.stdin, process.stdout
  reset = !->
    readline.line = code := ''
    readline.prompt!
  ({_ttyWrite} = readline)_ttyWrite = (chr) ->
    cont := chr in [ \\n, \> ]
    _ttyWrite ...
  prompt = \livescript
  prompt += " -#that" if [\b if o.bare; \c if o.compile]join ''
  LiveScript.history = readline.history if LiveScript?
  unless o.compile
    module.paths = module.._nodeModulePaths \
      module.filename = process.cwd! + \/repl
    vm = require \vm
    global <<< {module, exports, require}
    server = ^^require(\repl)REPLServer:: <<<
      context: global, commands: [], useGlobal: true
      eval: !(code,,, cb) ->
        try res = vm.runInThisContext code, \repl catch then err = e
        cb err, res
    readline.completer = server~complete
  readline.on \attemptClose !->
    if readline.line or code then say ''; reset! else readline.close!
  readline.on \close process.stdin~destroy
  readline.on \line !->
    repl.infunc = false if it.match(/^\s*$/) # close with a blank line
    cont = repl.infunc = true if it.match(/(\=|\~>|->|do|import|switch)\s*$/) or it.match(/^!?function /)
    if cont or repl.infunc
      code += it + \\n
      readline.output.write \. * prompt.length + '. '
      return
    code += it
    try
      if o.compile
        say LiveScript.compile code, {o.bare}
      else
        ops = {\eval, +bare, saveScope:LiveScript}
        ops = {+bare} if code.match(/^\s*!?function/)
        _  = vm.runInThisContext LiveScript.compile(code, ops), \repl
        _ !? global <<< {_}
        pp  _
        say _ if typeof _ is \function
    catch then say e
    reset!
  process.on \uncaughtException !-> say "\n#{ it?stack or it }"
  readline.setPrompt "#prompt> "
  readline.prompt!

# Start up a new __node.js__ instance with the arguments in `--nodejs` passed
# to it, preserving the other options.
!function forkNode
  args = argv.slice 1; i = 0
  while args[++i] when that in <[ -n --nodejs ]> then args.splice i-- 2
  require(\child_process)spawn do
    process.execPath
    o.nodejs.join(' ')trim!split(/\s+/)concat args
    cwd: process.cwd!, env: process.env, customFds: [0 to 2]

function help then """
  Usage: livescript [options] [files] [arguments]

  Options:
  #o
"""

function version then "LiveScript #{LiveScript.VERSION}"

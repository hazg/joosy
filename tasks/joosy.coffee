module.exports = (grunt) ->

  Sugar   = require 'sugar'
  Path    = require 'path'
  connect = require 'connect'
  Mincer  = require 'mincer'

  paths =
    haml:        Path.join('source', 'haml')
    javascript:  Path.join('source', 'javascript')
    stylesheets: Path.join('source', 'stylesheets')
    public:      'public'

  grunt.joosy =
    helpers:
      normalizeFiles: (config, target) ->
        entries = grunt.config.get(config) || {}
        entries = if target
          grunt.config.requires "#{config}.#{target}"
          [ entries[entry] ]
        else
          Object.values entries

        entries

      expandFiles: (root, entry) ->
        root  = Path.join(root, entry.cwd) if entry.cwd?
        files = grunt.file.expand({cwd: Path.join(process.cwd(), root)}, entry.src)

        return {
          cwd: root,
          list: files.map (file) ->
            src:      file
            extname:  Path.extname file
            filename: Path.basename file, Path.extname(file)
            dirname:  Path.dirname file
        }

    assets:
      instance: (environment='development') ->
        Mincer.logger.use console
        Mincer.StylusEngine.registerConfigurator (stylus) ->
          stylus.options.paths.push Path.join(process.cwd(), paths.public)
          stylus.define '$environment', environment
          stylus.define '$config', grunt.config.get('joosy.config') || {}
          stylus.use require('nib')()

        assets = new Mincer.Environment(process.cwd())
        assets.appendPath paths.javascript
        assets.appendPath paths.stylesheets
        assets.appendPath 'vendor'
        assets.appendPath 'bower_components'
        assets.appendPath 'node_modules/joosy/src'

        assets

      compile: (environment, map, callbacks) ->
        assets = grunt.joosy.assets.instance(environment)
        deepness = 0

        for entry in map
          do (entry) ->
            deepness++
            asset = assets.findAsset entry.src
            callbacks.error? "Cannot find #{entry.src}" unless asset

            asset.compile (err) ->
              deepness--
              callbacks.error? asset, err if err
              grunt.file.write entry.dest, asset.toString()
              callbacks.compiled? asset, entry.dest
              callbacks.success?() if deepness == 0

    haml:
      compile: (file, partials=paths.haml, environment='development', locals={}) ->
        HAMLC = require 'haml-coffee'

        HAMLC.compile(grunt.file.read file)(
          Object.merge locals,
            environment: environment
            config: grunt.config.get('joosy.config') || {}
            partial: (location, locals) ->
              grunt.joosy.haml.compile(Path.join(partials, location), partials, environment, locals)
        )

    server:
      start: (port, setup) ->
        server = connect()
        setup?(server)
        server.listen port

        console.log "=> Started on 4000\n"

      serveProxied: (server, map) ->
        URL   = require 'url'
        proxy = require 'proxy-middleware'

        return unless map?

        for entry in map
          [from, to] = if entry.src
            [entry.src, entry.dest]
          else
            key = Object.keys(entry).first()
            [key, entry[key]]

          server.use from, proxy(URL.parse to)
          console.log "=> Proxying #{from} to #{to}"

      serveAssets: (server, path='/assets') ->
        assets = grunt.joosy.assets.instance()
        server.use path, Mincer.createServer(assets)

        console.log "=> Serving assets from #{path}"

      serveHAML: (server, map) ->
        serve = (urls, template, partials) ->
          urls = [urls] unless Object.isArray(urls)

          for url in urls
            do (url) ->
              server.use url, (req, res, next) ->
                if req.originalUrl == url
                  res.end grunt.joosy.haml.compile(template, partials)
                  console.log "Served #{url} (#{template})"
                else
                  next()
          console.log "=> Serving #{template} from #{urls.join(', ')}"

        for entry in map
          do (entry) ->
            unless entry.expand
              serve(entry.url, Path.join(paths.haml, entry.src), entry.partials)
            else
              files = grunt.joosy.helpers.expandFiles(paths.haml, entry)

              for file in files.list
                serve(
                  entry.url(file),
                  Path.join(files.cwd, file.src),
                  entry.partials
                )

      serveStatic: (server, compress=false) ->
        unless compress
          server.use connect.static(paths.public)
        else
          Gzippo = require 'gzippo'
          server.use Gzippo.staticGzip(paths.public)

        console.log "=> Serving static from /#{paths.public}"

    bower: -> require('bower')

  # Tasks
  grunt.registerTask 'joosy:postinstall', ->
    complete  = @async()
    bowerized = ->
      if process.env['NODE_ENV'] == 'production'
        grunt.task.run 'compile'

      complete()

    if grunt.file.exists('bower.json')
      grunt.joosy.bower().commands.install()
        .on('data', (msg) -> grunt.log.ok msg)
        .on('error', (error) -> grunt.fail.fatal(error))
        .on('end', bowerized)
    else
      bowerized()

  grunt.registerTask 'joosy:server', ->
    @async()
    
    grunt.joosy.server.start 4000, (server) ->
      grunt.joosy.server.serveAssets server
      grunt.joosy.server.serveHAML server, grunt.joosy.helpers.normalizeFiles('joosy.haml')
      grunt.joosy.server.serveProxied server, grunt.config.get('joosy.server.proxy')
      grunt.joosy.server.serveStatic server

  grunt.registerTask 'joosy:server:production', ->
    @async()

    grunt.joosy.server.start process.env['PORT'] ? 4000, (server) ->
      grunt.joosy.server.serveStatic server, true

  grunt.registerTask 'joosy:compile', ['joosy:assets', 'joosy:haml']

  grunt.registerTask 'joosy:assets', (target) ->
    complete = @async()
    assets   = grunt.joosy.helpers.normalizeFiles('joosy.assets', target)

    grunt.joosy.assets.compile 'production', assets,
      error: (asset, msg) -> grunt.fail.fatal msg
      compiled: (asset, dest) -> grunt.log.ok "Compiled #{dest}"
      success: complete

  grunt.registerTask 'joosy:haml', (target) ->
    for _, entry of grunt.joosy.helpers.normalizeFiles('joosy.haml', target)
      unless entry.expand
        grunt.file.write entry.dest, grunt.joosy.haml.compile(
            Path.join(paths.haml, entry.src),
            entry.partials,
            'production'
          )

        grunt.log.ok "Compiled #{entry.dest}"
      else
        files = grunt.joosy.helpers.expandFiles(paths.haml, entry)

        for file in files.list
          destination = Path.join entry.dest, file.dirname, file.filename+(entry.ext || '.html')

          grunt.file.write destination, grunt.joosy.haml.compile(
              Path.join(files.cwd, file.src),
              entry.partials,
              'production'
            )

          grunt.log.ok "Compiled #{destination}"


  grunt.registerTask 'joosy:clean', ->
    trash = []

    for entry in grunt.joosy.helpers.normalizeFiles('joosy.assets')
      trash.push entry.dest

    for entry in grunt.joosy.helpers.normalizeFiles('joosy.haml')
      unless entry.expand
        trash.push entry.dest
      else
        files = grunt.joosy.helpers.expandFiles(paths.haml, entry)

        for file in files.list
          trash.push Path.join(entry.dest, file.dirname, file.filename+(entry.ext || '.html'))

    for file in trash
      if grunt.file.exists(file)
        grunt.file.delete(file)
        grunt.log.warn "Removed #{file}"
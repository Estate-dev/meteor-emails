# `lookback:emails` is a small package for Meteor which helps you
# tremendously in the process of building, testing and debugging
# HTML emails in Meteor applications.
#
# See the [GitHub repo](https://github.com/lookback/meteor-emails) for README.
# Made by Johan Brook for [Lookback](https://github.com/lookback).

TAG = 'mailer'

# ## Setup

# Main exported symbol with some initial settings:
#
# - `routePrefix` is the top level path for the preview and send routes (see further down).
# - `baseUrl` is what root domain to base relative paths from.
# - `testEmail`, when testing emails, set this variable.
# - `logger`, optionally inject an external logger. Defaults to `console`.
Mailer =
  settings:
    routePrefix: 'emails'
    baseUrl: process.env.ROOT_URL
    testEmail: null
    logger: console

  config: (newSettings) ->
    @settings = _.extend(@settings, newSettings)

# ## Deps
#
# Use `juice` for inlining CSS into the templates.
juice = Npm.require 'juice'
Utils = share.MailerUtils

# ## Template helpers
#
# Built-in template helpers.
Helpers =

  # `baseUrl` gives you a full absolute URL from a relative path.
  #
  #     {{ baseUrl '/some-path' }} => http://root-domain.com/some-path
  baseUrl: (path) ->
    Utils.joinUrl(Mailer.settings.baseUrl, path)

  # `emailUrlFor` takes an Iron Router route (with optional params) and
  # creates an absolute URL.
  #
  #     {{ emailUrlFor 'myRoute' param='foo' }} => http://root-domain.com/my-route/foo
  emailUrlFor: (route, params) ->
    if Router
      Utils.joinUrl Mailer.settings.baseUrl, Router.path.call(Router, route, params.hash)

# # The mailer
#
# This is the "blueprint" of the Mailer object. It has the following interface:
#
# - `precompile`
# - `render`
# - `send`
#
# As you can see, the mailer takes care of precompiling and rendering templates
# with data, as well as sending emails from those templates.

MailerClass = (options) ->
  check options, Match.ObjectIncluding(
    # Mailer *must* take a `templates` object with template names as keys.
    templates: Object
    # Take optional template helpers.
    helpers: Match.Optional Object
    # Take an optional layoute template object.
    layout: Match.Optional Object
  )

  settings = _.extend({}, Mailer.settings, options.settings)
  globalHelpers = _.extend({}, Helpers, Blaze._globalHelpers, options.helpers)

  Utils.setupLogger(settings.logger)

  addHelpers = (template) ->
    check template.name, String
    check template.helpers, Match.Optional Object

    # Use the built-in helpers, any global Blaze helpers, and injected helpers
    # from options, and *additional* template helpers, and apply them to
    # the template.
    Template[template.name].helpers _.extend({}, globalHelpers, template.helpers)

  # ## Compile
  #
  # Function for compiling a template with a name and path to
  # a HTML file to a template function, to be placed
  # in the Template namespace.
  #
  # A `template` must have a path to a template HTML file, and
  # can optionally have paths to any SCSS and CSS stylesheets.
  compile = (template) ->
    check template, Match.ObjectIncluding(
      path: String
      name: String
      scss: Match.Optional String
      css: Match.Optional String
    )

    # Read the template as a string.
    try
      content = Utils.readFile template.path
    catch ex
      Utils.Logger.error 'Could not read template file: '+template.path, TAG
      return false

    juiceOpts =
      preserveMediaQueries: true
      removeStyleTags: true
      webResources:
        images: false

    addCSS = (css, html) ->
      return html if not css

      try
        return juice.inlineContent(html, css, juiceOpts)
      catch ex
        Utils.Logger.error 'Could not add CSS to '+template.name+': ' + ex.message, TAG
        return html

    # .. then any attached CSS file paths.
    if template.css
      content = addCSS Utils.readFile(template.css), content

    # .. and compile and inline any SCSS file paths.
    if template.scss
      content = addCSS Utils.toCSS(template.scss), content

    if options.layout? and template.layout isnt false
      layout = options.layout
      layoutContent = Utils.readFile(layout.path)

      if layout.css
        layoutContent = addCSS Utils.readFile(layout.css), layoutContent
        content = addCSS Utils.readFile(layout.css), content

      if layout.scss
        layoutContent = addCSS Utils.toCSS(layout.scss), layoutContent
        content = addCSS Utils.toCSS(layout.scss), content

      if template.css
        layoutContent = addCSS Utils.readFile(template.css), layoutContent

      if template.scss
        layoutContent = addCSS Utils.toCSS(template.scss), layoutContent

      SSR.compileTemplate(layout.name, layoutContent)
      addHelpers layout


    # This will place the template function in
    #
    #     Template.<template.name>
    tmpl = SSR.compileTemplate(template.name, content)

    # Save the layout name on the template object for later.
    if layout?
      tmpl.__layout = layout.name

    # Add helpers to template.
    addHelpers template

    return tmpl

  # ## Render
  #
  # Render a template by name, with optional data context.
  # Will compile the template if not done already.
  render = (templateName, data) ->
    check templateName, String
    check data, Match.Optional Object

    template = _.findWhere(options.templates, name: templateName)

    if not Template[templateName]
      compile template

    tmpl = Template[templateName]

    if not tmpl
      throw new Meteor.Error 500, 'Could not find template: '+templateName

    rendered = SSR.render tmpl, data

    if tmpl.__layout?
      layout = tmpl.__layout

      # When applying to a layout, some info from the template
      # (like the first preview lines) needs to be applied to the
      # layout scope as well.
      #
      # Thus we fetch a `preview` helper from the template or
      # `preview` prop in the data context to apply to the layout.
      if tmpl.__helpers.has 'preview'
        preview = tmpl.__helpers.get('preview')
      else if data.preview
        preview = data.preview

      # The `extraCSS` property on a `template` is applied to
      # the layout in `<style>` tags. Ideal for media queries.
      if template.extraCSS
        try
          css = Utils.readFile template.extraCSS
        catch ex
          Utils.Logger.error 'Could not add extra CSS when rendering '+templateName+': '+ex.message, TAG

      layoutData = _.extend({}, data,
        body: rendered
        css: css
        preview: preview
      )

      rendered = SSR.render layout, layoutData

    Utils.addDoctype rendered

  # ## Send
  #
  # The main sending-email function. Takes a set of usual email options,
  # including the template name and optional data object.
  sendEmail = (options) ->
    check options,
      to: String
      subject: String
      template: String
      replyTo: Match.Optional String
      from: Match.Optional String
      data: Match.Optional Object

    defaults =
      from: settings.from

    if settings.replyTo
      defaults.replyTo = settings.replyTo

    opts = _.extend {}, defaults, options

    # Render HTML with optional data context.
    try
      opts.html = render options.template, options.data
    catch ex
      Utils.Logger.error 'Could not render email before sending: ' + ex.message, TAG
      return false

    # Send email
    try
      Email.send(opts)
      return true
    catch ex
      Utils.Logger.error 'Could not send email: ' + ex.message, TAG
      return false


  # ## Routes
  #
  # This package supports browser routes, so you can **preview**
  # and **send email designs** from the browser.

  Routes =

    # This function adds the `preview` route from a `template` object.
    # It will apply the returned data from a `data` function on the
    # provided `route` prop from the template.
    addPreview: (template) ->
      check template.name, String
      check template.route,
        path: String
        data: Match.Optional Function

      # Typically `/emails/preview/myEmailTemplate`.
      path = settings.routePrefix + '/preview' + template.route.path

      Utils.Logger.info 'Adding route: /' + path, TAG

      Router.route "preview#{template.name}Email",
        path: path
        where: 'server'
        action: ->

          try
            data = template.route.data and template.route.data.apply(this, arguments)
          catch ex
            msg = 'Exception in '+template.name+' data function: '+ex.message
            Utils.Logger.error msg, TAG
            @response.writeHead 500
            return @response.end msg

          # Compile, since we wanna refresh markup and CSS inlining.
          compile template

          Utils.Logger.info "Rendering #{template.name} ...", TAG

          try
            html = render template.name, data
            Utils.Logger.info "Rendering successful!", TAG
          catch ex
            msg = 'Could not preview email: ' + ex.message
            Utils.Logger.error msg, TAG
            html = msg

          @response.writeHead 200, 'Content-Type': 'text/html'
          @response.end(html, 'utf8')

    # This function adds the `send` route, for easy sending emails from
    # the browser.
    addSend: (template) ->
      check template.name, String
      check template.route,
        path: String
        data: Match.Optional Function

      path = settings.routePrefix + '/send' + template.route.path

      Utils.Logger.info 'Adding route /' + path, TAG

      Router.route "send#{template.name}Email",
        path: path
        where: 'server'
        action: ->
          # Who to send to? It depends: it primarly reads from the `?to`
          # query param, and secondly from the `testEmail` prop in settings.
          to = @params.query.to or settings.testEmail

          Utils.Logger.info "Sending #{template.name} ...", TAG

          if to?
            try
              data = template.route.data and template.route.data.apply(this, arguments)
            catch ex
              Utils.Logger.error 'Exception in '+template.name+' data function: '+ex.message, TAG
              return

            res = sendEmail(
              to: to
              data: data
              template: template.name
              subject: '[TEST] ' + template.name
            )

            if res is false
              @response.writeHead 500
              msg = 'Did not send test email, something went wrong. Check the logs.'
            else
              @response.writeHead 200
              # If there's no `MAIL_URL` environment variable, Meteor cannot send
              # the email and echoes it out to `STDOUT` instead.
              reallySentEmail = !!process.env.MAIL_URL
              msg = if reallySentEmail then "Sent test email to #{to}" else "Sent email to STDOUT"

            @response.end(msg)

          else
            @response.writeHead 400
            @response.end("No testEmail provided.")

  # ## Init
  #
  # Init routine. Precompiles all templates provided and
  # setup routes if provided and if in dev mode.
  init = ->
    if options.templates
      _.each options.templates, (template, name) ->
        template.name = name

        compile template

        # Only add these routes when in dev mode.
        if template.route and process.env.NODE_ENV is 'development'
          Routes.addPreview template
          Routes.addSend template

  init()

  # ## Export
  #
  # The "interface".
  precompile: compile
  render: render
  send: sendEmail

# Exported symbol
#
# I wanna export a singleton symbol with an 'init'
# method, but still initialize variables in the main
# function body of 'MailerClass'.
Mailer.init = (opts) ->
  mailer = MailerClass(opts)

  _.extend(this, mailer)

StartView = null
InputView = null
AlertView = null
SharePane = null

require './pusher/pusher'
require './pusher/pusher-js-client-auth'

{CompositeDisposable} = require 'atom'

randomstring = null
_ = null
chunkString = null

HipChatInvite = null
SlackInvite = null
AtomPairConfig = null
CustomPaste = null

module.exports = AtomPair =

  AtomPairView: null
  modalPanel: null
  subscriptions: null

  config:
    hipchat_token:
      type: 'string'
      description: 'HipChat admin token (optional)'
      default: ''
    hipchat_room_name:
      type: 'string'
      description: 'HipChat room name for sending invitations (optional)'
      default: ''
    pusher_app_key:
      type: 'string'
      description: 'Pusher App Key (sign up at http://pusher.com/signup and change for added security)'
      default: 'd41a439c438a100756f5'
    pusher_app_secret:
      type: 'string'
      description: 'Pusher App Secret'
      default: '4bf35003e819bb138249'
    slack_url:
      type: 'string'
      description: 'WebHook URL for Slack Incoming Webhook Integration'
      default: ''

  activate: (state) ->

    SharePane = require './modules/share_pane'

    StartView = require './views/start-view'
    InputView = require './views/input-view'
    AlertView = require './views/alert-view'

    randomstring = require 'randomstring'
    _ = require 'underscore'
    chunkString = require './helpers/chunk-string'

    HipChatInvite = require './modules/hipchat_invite'
    SlackInvite = require './modules/slack_invite'

    AtomPairConfig = require './modules/atom_pair_config'

    # Events subscribed to in atom's system can be easily cleaned up with a CompositeDisposable
    @subscriptions = new CompositeDisposable

    # Register command that toggles this view
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:start new pairing session': => @startSession()
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:join pairing session': => @joinSession()
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:invite over hipchat': => @inviteOverHipChat()
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:invite over slack': => @inviteOverSlack()
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:allow directory share': => @allowDirectoryShare()


    @subscriptions.add atom.commands.add '.session-id', 'AtomPair:copyid': => @copyId()

    @colours = require('./helpers/colour-list')
    @friendColours = []
    @sharePanes = []
    _.extend(@, HipChatInvite, SlackInvite, AtomPairConfig)

  disconnect: ->
    @pusher.disconnect()
    _.each @friendColours, (colour) => @clearMarkers(colour)
    @markerColour = null

  copyId: -> atom.clipboard.write(@sessionId)

  joinSession: ->

    if @markerColour
      alreadyPairing = new AlertView "It looks like you are already in a pairing session. Please open a new window (cmd+shift+N) to start/join a new one."
      return

    joinView = new InputView("Enter the session ID here:")
    joinView.miniEditor.focus()

    atom.commands.add joinView.element, 'core:confirm': =>
      @sessionId = joinView.miniEditor.getText()
      keys = @sessionId.split("-")
      [@app_key, @app_secret] = [keys[0], keys[1]]
      joinView.panel.hide()
      # atom.workspace.open().then => @pairingSetup() #starts a new tab to join pairing session
      @pairingSetup()

  startSession: ->

    @getKeysFromConfig()

    if @missingPusherKeys()
      new AlertView "Please set your Pusher keys."
    else
      @generateSessionId()
      new StartView(@sessionId)
      @markerColour = @colours[0]
      @leader = true
      @pairingSetup()

  generateSessionId: ->
    @sessionId = "#{@app_key}-#{@app_secret}-#{randomstring.generate(11)}"

  ensureActiveTextEditor: ->
    editor = atom.workspace.getActiveTextEditor()
    if !editor
      atom.workspace.open().then =>
        @ensureActiveTextEditor()
    else
      editor

  pairingSetup: ->
    @connectToPusher()
    @synchronizeColours()
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:custom-paste': => @customPaste()
    @subscriptions.add atom.commands.add 'atom-workspace', 'AtomPair:disconnect': => @disconnect()

  connectToPusher: ->
    @pusher = new Pusher @app_key,
      authTransport: 'client'
      clientAuth:
        key: @app_key
        secret: @app_secret
        user_id: @markerColour || "blank"

    @globalChannel = @pusher.subscribe("presence-session-#{@sessionId}")

  synchronizeColours: ->
    @globalChannel.bind 'pusher:subscription_succeeded', (members) =>
      @membersCount = members.count
      return @resubscribe() unless @markerColour
      colours = Object.keys(members.members)
      @friendColours = _.without(colours, @markerColour)
      _.each @friendColours, (colour) =>
        _.each @sharePanes, (pane) ->
          pane.addMarker 0, colour
      @startPairing()

  resubscribe: ->
    @globalChannel.unsubscribe()
    @markerColour = @colours[@membersCount - 1]
    @connectToPusher()
    @synchronizeColours()

  setUpLeadership: ->

    editor = @ensureActiveTextEditor()

    sharePane = new SharePane({
      editor: editor,
      pusher: @pusher,
      sessionId: @sessionId
    })

    sharePane.subscribe()
    sharePane.activate()

    @sharePanes.push(sharePane)
    @listenForNewTab()

    console.log(@sharePanes)


  startPairing: ->
    # editor = atom.workspace.getActiveTextEditor()

    # console.log(@sharePanes)
    if @leader then @setUpLeadership()

    # @listenForNewTab()


    @globalChannel.bind 'client-created-share-pane',(data) =>
      return unless data.to is @markerColour or data.to is 'all'
      sharePane = SharePane.id(data.paneId)
      sharePane.shareFile()
      sharePane.sendGrammar()

    @globalChannel.bind 'client-create-share-pane', (data) =>
      console.log(data)
      return unless data.to is @markerColour or data.to is 'all'
      paneId = data.paneId
      atom.workspace.open().then (editor)=>
        sharePane = new SharePane({
          id: paneId,
          pusher: @pusher,
          editor: editor,
          sessionId: @sessionId
        })
        sharePane.subscribe()
        sharePane.activate()
        @sharePanes.push(sharePane)
        console.log('created share pane')
        @globalChannel.trigger 'client-created-share-pane', {to: data.from, paneId: paneId}

    # GLOBAL
    @globalChannel.bind 'pusher:member_added', (member) =>
      noticeView = new AlertView "Your pair buddy has joined the session."
      @friendColours.push(member.id)
      return unless @leader
      _.each @sharePanes, (sharePane) =>
        @globalChannel.trigger('client-create-share-pane', {
          to: member.id,
          from: @markerColour,
          paneId: sharePane.id
        })
        sharePane.addMarker(0, member.id)


    # GLOBAL
    @globalChannel.bind 'pusher:member_removed', (member) =>

      _.each @sharePanes, (sharePane) ->
        sharePane.clearMarkers(member.id)

      disconnectView = new AlertView "Your pair buddy has left the session."
      if member.id is 'red' and @markerColour is 'blue' # TODO: MAKE LEADERSHIP SYSTEM
        @leader = true
        @setUpLeadership()
    # listening for its own demise
    @listenForDestruction()



  listenForNewTab: ->
    atom.workspace.onDidOpen (e) =>
      editor = e.item
      sharePane = new SharePane({
        pusher: @pusher,
        editor: editor,
        sessionId: @sessionId
      })
      sharePane.subscribe()
      sharePane.activate()
      @sharePanes.push(sharePane)
      console.log(@sharePanes)
      @globalChannel.trigger('client-create-share-pane', {
        to: 'all',
        from: @markerColour,
        paneId: sharePane.id
      })

  listenForDestruction: ->
    _.each @sharePanes, (sharePane) =>
      sharePane.disconnectEmitter.on 'disconnected', =>
        if (_.none @sharePanes, (pane) => pane.connected) then @disconnect()

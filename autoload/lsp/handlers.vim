vim9script

# Handlers for messages from the LSP server
# Refer to https://microsoft.github.io/language-server-protocol/specification
# for the Language Server Protocol (LSP) specification.

import './util.vim'
import './diag.vim'
import './textedit.vim'

# Process various reply messages from the LSP server
export def ProcessReply(lspserver: dict<any>, req: dict<any>, reply: dict<any>): void
  util.ErrMsg($'Unsupported reply received from LSP server: {reply->string()} for request: {req->string()}')
enddef

# process a diagnostic notification message from the LSP server
# Notification: textDocument/publishDiagnostics
# Param: PublishDiagnosticsParams
def ProcessDiagNotif(lspserver: dict<any>, reply: dict<any>): void
  diag.DiagNotification(lspserver, reply.params.uri, reply.params.diagnostics)
enddef

# Convert LSP message type to a string
def LspMsgTypeToString(lspMsgType: number): string
  var msgStrMap: list<string> = ['', 'Error', 'Warning', 'Info', 'Log']
  var mtype: string = 'Log'
  if lspMsgType > 0 && lspMsgType < 5
    mtype = msgStrMap[lspMsgType]
  endif
  return mtype
enddef

# process a show notification message from the LSP server
# Notification: window/showMessage
# Param: ShowMessageParams
def ProcessShowMsgNotif(lspserver: dict<any>, reply: dict<any>)
  if reply.params.type >= 4
    # ignore log messages from the LSP server (too chatty)
    # TODO: Add a configuration to control the message level that will be
    # displayed. Also store these messages and provide a command to display
    # them.
    return
  endif
  if reply.params.type == 1
    util.ErrMsg($'Lsp({lspserver.name}) {reply.params.message}')
  elseif reply.params.type == 2
    util.WarnMsg($'Lsp({lspserver.name}) {reply.params.message}')
  elseif reply.params.type == 3
    util.InfoMsg($'Lsp({lspserver.name}) {reply.params.message}')
  endif
enddef

# process a log notification message from the LSP server
# Notification: window/logMessage
# Param: LogMessageParams
def ProcessLogMsgNotif(lspserver: dict<any>, reply: dict<any>)
  var mtype = LspMsgTypeToString(reply.params.type)
  lspserver.addMessage(mtype, reply.params.message)
enddef

# process the log trace notification messages
# Notification: $/logTrace
# Param: LogTraceParams
def ProcessLogTraceNotif(lspserver: dict<any>, reply: dict<any>)
  lspserver.addMessage('trace', reply.params.message)
enddef

# process unsupported notification messages
def ProcessUnsupportedNotif(lspserver: dict<any>, reply: dict<any>)
  util.ErrMsg($'Unsupported notification message received from the LSP server ({lspserver.path}), message = {reply->string()}')
enddef

# per-filetype private map inside to record if ntf once or not
var ftypeNtfOnceMap: dict<bool> = {}
# process unsupported notification messages but only notify once
def ProcessUnsupportedNotifOnce(lspserver: dict<any>, reply: dict<any>)
  if !ftypeNtfOnceMap->get(&ft, v:false)
	ProcessUnsupportedNotif(lspserver, reply)
	ftypeNtfOnceMap->extend({[&ft]: v:true})
  endif
enddef

# process notification messages from the LSP server
export def ProcessNotif(lspserver: dict<any>, reply: dict<any>): void
  var lsp_notif_handlers: dict<func> =
    {
      'window/showMessage': ProcessShowMsgNotif,
      'window/logMessage': ProcessLogMsgNotif,
      'textDocument/publishDiagnostics': ProcessDiagNotif,
      '$/logTrace': ProcessLogTraceNotif,
      'telemetry/event': ProcessUnsupportedNotifOnce,
    }

  # Explicitly ignored notification messages
  var lsp_ignored_notif_handlers: list<string> =
    [
      '$/progress',
      '$/status/report',
      '$/status/show',
      # PHP intelephense server sends the 'indexingStarted' and
      # 'indexingEnded' notifications which is not in the LSP specification.
      'indexingStarted',
      'indexingEnded',
      # Java language server sends the 'language/status' notification which is
      # not in the LSP specification.
      'language/status',
      # Typescript language server sends the '$/typescriptVersion'
      # notification which is not in the LSP specification.
      '$/typescriptVersion'
    ]

  if lsp_notif_handlers->has_key(reply.method)
    lsp_notif_handlers[reply.method](lspserver, reply)
  elseif lspserver.customNotificationHandlers->has_key(reply.method)
    lspserver.customNotificationHandlers[reply.method](lspserver, reply)
  elseif lsp_ignored_notif_handlers->index(reply.method) == -1
    util.ErrMsg($'Unsupported notification received from LSP server {reply->string()}')
  endif
enddef

# process the workspace/applyEdit LSP server request
# Request: "workspace/applyEdit"
# Param: ApplyWorkspaceEditParams
def ProcessApplyEditReq(lspserver: dict<any>, request: dict<any>)
  # interface ApplyWorkspaceEditParams
  if !request->has_key('params')
    return
  endif
  var workspaceEditParams: dict<any> = request.params
  if workspaceEditParams->has_key('label')
    util.InfoMsg($'Workspace edit {workspaceEditParams.label}')
  endif
  textedit.ApplyWorkspaceEdit(workspaceEditParams.edit)
  # TODO: Need to return the proper result of the edit operation
  lspserver.sendResponse(request, {applied: true}, {})
enddef

# process the workspace/workspaceFolders LSP server request
# Request: "workspace/workspaceFolders"
# Param: none
def ProcessWorkspaceFoldersReq(lspserver: dict<any>, request: dict<any>)
  if !lspserver->has_key('workspaceFolders')
    lspserver.sendResponse(request, null, {})
    return
  endif
  if lspserver.workspaceFolders->empty()
    lspserver.sendResponse(request, [], {})
  else
    lspserver.sendResponse(request,
	  \ lspserver.workspaceFolders->copy()->map('{name: v:val->fnamemodify(":t"), uri: util.LspFileToUri(v:val)}'),
	  \ {})
  endif
enddef

# process the workspace/configuration LSP server request
# Request: "workspace/configuration"
# Param: ConfigurationParams
def ProcessWorkspaceConfiguration(lspserver: dict<any>, request: dict<any>)
  var items = request.params.items
  var response = items->map((_, item) => lspserver.workspaceConfigGet(item))
  lspserver.sendResponse(request, response, {})
enddef

# process the window/workDoneProgress/create LSP server request
# Request: "window/workDoneProgress/create"
# Param: none
def ProcessWorkDoneProgressCreate(lspserver: dict<any>, request: dict<any>)
  lspserver.sendResponse(request, {}, {})
enddef

# process the client/registerCapability LSP server request
# Request: "client/registerCapability"
# Param: RegistrationParams
def ProcessClientRegisterCap(lspserver: dict<any>, request: dict<any>)
  lspserver.sendResponse(request, {}, {})
enddef

# process the client/unregisterCapability LSP server request
# Request: "client/unregisterCapability"
# Param: UnregistrationParams
def ProcessClientUnregisterCap(lspserver: dict<any>, request: dict<any>)
  lspserver.sendResponse(request, {}, {})
enddef

def ProcessUnsupportedReq(lspserver: dict<any>, request: dict<any>)
  util.ErrMsg($'Unsupported request message received from the LSP server ({lspserver.path}), message = {request->string()}')
enddef

# process a request message from the server
export def ProcessRequest(lspserver: dict<any>, request: dict<any>)
  var lspRequestHandlers: dict<func> =
    {
      'workspace/applyEdit': ProcessApplyEditReq,
      'workspace/workspaceFolders': ProcessWorkspaceFoldersReq,
      'window/workDoneProgress/create': ProcessWorkDoneProgressCreate,
      'client/registerCapability': ProcessClientRegisterCap,
      'client/unregisterCapability': ProcessClientUnregisterCap,
      'workspace/configuration': ProcessWorkspaceConfiguration,
      'workspace/codeLens/refresh': ProcessUnsupportedReq,
      'workspace/semanticTokens/refresh': ProcessUnsupportedReq
    }

  if lspRequestHandlers->has_key(request.method)
    lspRequestHandlers[request.method](lspserver, request)
  else
    util.ErrMsg($'Unsupported request message received from the LSP server ({lspserver.path}), message = {request->string()}')
  endif
enddef

# process one or more LSP server messages
export def ProcessMessages(lspserver: dict<any>): void
  var idx: number
  var len: number
  var content: string
  var msg: dict<any>
  var req: dict<any>

  msg = lspserver.data
  if msg->has_key('result') || msg->has_key('error')
    # response message from the server
    req = lspserver.requests->get(msg.id->string(), {})
    if !req->empty()
      # Remove the corresponding stored request message
      lspserver.requests->remove(msg.id->string())

      if msg->has_key('result')
	lspserver.processReply(req, msg)
      else
	# request failed
	var emsg: string = msg.error.message
	emsg ..= $', code = {msg.error.code}'
	if msg.error->has_key('data')
	  emsg ..= $', data = {msg.error.data->string()}'
	endif
	util.ErrMsg($'request {req.method} failed ({emsg})')
      endif
    endif
  elseif msg->has_key('id') && msg->has_key('method')
    # request message from the server
    lspserver.processRequest(msg)
  elseif msg->has_key('method')
    # notification message from the server
    lspserver.processNotif(msg)
  else
    util.ErrMsg($'Unsupported message ({msg->string()})')
  endif
enddef

# vim: tabstop=8 shiftwidth=2 softtabstop=2

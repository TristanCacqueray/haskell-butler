module Butler.Window where

import Data.IntMap.Strict qualified as IM
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Lucid

import Butler.GUI
import Butler.Memory
import Butler.Prelude
import Butler.Process

newtype WinID = WinID Int
    deriving newtype (Eq, Ord, Show, ToJSON, Serialise)

data Window = Window
    { position :: (Int, Int)
    , size :: (Int, Int)
    , title :: Text
    }
    deriving (Eq, Generic, Serialise)

data WindowsState = WindowsState
    { windows :: IntMap Window
    , maxID :: WinID
    , focus :: Maybe WinID
    }
    deriving (Generic, Serialise)

type Windows = MemoryVar WindowsState

data WindowManager = WindowManager
    { windows :: MemoryVar WindowsState
    , apps :: MemoryVar (Map WinID ProgramName)
    , running :: TVar (Map WinID GuiApp)
    }

newWindowManager :: ProcessIO WindowManager
newWindowManager =
    WindowManager
        <$> (snd <$> newProcessMemory "wins.bin" (pure newWindows))
        <*> (snd <$> newProcessMemory "apps.bin" (pure mempty))
        <*> newTVarIO mempty

newWindows :: WindowsState
newWindows = WindowsState mempty (WinID 0) Nothing

addWindowApp :: WindowManager -> WinID -> GuiApp -> STM ()
addWindowApp wm wid app = do
    modifyTVar' wm.running (Map.insert wid app)
    modifyMemoryVar wm.apps (Map.insert wid app.process.program)
    void $ updateWindow wm.windows wid (#title .~ processID app.process)

delWindowApp :: WindowManager -> WinID -> STM ()
delWindowApp wm wid = do
    deleteWindow wm.windows wid
    modifyTVar' wm.running (Map.delete wid)
    modifyMemoryVar wm.apps (Map.delete wid)

lookupWindow :: Windows -> WinID -> STM (Maybe Window)
lookupWindow ws (WinID wid) = IM.lookup wid . (.windows) <$> readMemoryVar ws

deleteWindow :: Windows -> WinID -> STM ()
deleteWindow ws (WinID wid) = modifyMemoryVar ws (#windows %~ IM.delete wid)

updateWindow :: Windows -> WinID -> (Window -> Window) -> STM Bool
updateWindow ws (WinID wid) f = stateMemoryVar ws $ \s ->
    case IM.lookup wid s.windows of
        Nothing -> (False, s)
        Just win ->
            let newWin = f win
             in if newWin == win
                    then (False, s)
                    else (True, s & #windows %~ IM.insert wid newWin)

newWindow :: Windows -> Text -> STM (WinID, Window)
newWindow ws title = stateMemoryVar ws $ \s ->
    let WinID prev = s.maxID
        next = prev + 1
        wid = WinID next
        win =
            Window
                (0 + 23 * next, 0 + 23 * next)
                (640, 420)
                title
     in ((wid, win), s & (#maxID .~ wid) . (#windows %~ IM.insert next win))

renderWindowsContent :: Windows -> HtmlT STM ()
renderWindowsContent ws = do
    wins <- IM.toAscList . (.windows) <$> lift (readMemoryVar ws)
    forM_ wins $ \(idx, _) ->
        with div_ [id_ $ "w-" <> showT idx] mempty

renderWindows :: Windows -> HtmlT STM ()
renderWindows ws = do
    w <- lift (readMemoryVar ws)
    let createWindows = map (renderWindow . first WinID) (IM.toAscList w.windows)
    let script = windowScript : createWindows
    with (script_ $ Text.intercalate ";" script) [type_ "module"]

windowScript :: Text
windowScript =
    [raw|
import WinBox from '/xstatic/winbox.js'
globalThis.WinBox = WinBox
globalThis.onWinEvent = (ev, w) => debounceData(500, (x, y) => {
  if (ev == "resize" && onWindowResize[w] !== undefined) {
    onWindowResize[w]()
  }
  return encodeDataMessage(1, {ev: ev, w: w, x: x, y: y})
})
globalThis.onWinClose = (w) => (force) => {
  let doDelete = force
  if (!force && confirm("Close window?")) {
    butlerDataSocket.send(encodeDataMessage(1, {ev: "close", w: w}))
    doDelete = true
  }
  if (doDelete) {
    let div = document.getElementById("w-" + w);
    if (div) { div.remove(); }
    return false;
  }
  return true
}
butlerDataHandlers[1] = buf => {
  let body = decodeJSON(buf)
  let win = windows[body.w]
  let withoutHandler = (name, cb) => {
    // disable the handler to avoid bouncing loop effect
    let handler = win[name]
    win[name] = undefined
    cb()
    win[name] = handler
  }
  switch (body.ev) {
    case "move":
      withoutHandler("onmove", () => win.move(body.x, body.y))
      break
    case "resize":
      withoutHandler("onresize", () => {
        if (onWindowResize[body.w] !== undefined) {
          onWindowResize[body.w](body.x, body.y)
        }
        win.resize(body.x, body.y)
      })
      break
    case "focus":
      withoutHandler("onfocus", () => win.focus(true))
      break
    case "close":
      win.close(true)
      break
    case "title":
      win.setTitle(body.title)
      break
  }
}
|]

renderWindow :: (WinID, Window) -> Text
renderWindow (WinID idx, Window (x, y) (w, h) title) = do
    let attr k v = k <> ": " <> showT v
        handler n = "on" <> n <> ": onWinEvent(" <> showT n <> ", " <> showT idx <> ")"
        attrs =
            map handler ["resize", "move", "focus"] -- , minimize", "maximize"]
                <> [ attr "x" x
                   , attr "y" y
                   , attr "width" w
                   , attr "height" h
                   , "id: " <> showT idx
                   , "bottom: 36"
                   , "class: [\"no-full\"]"
                   , "root: document.getElementById(\"win-root\")"
                   , "onclose: onWinClose(" <> showT idx <> ")"
                   , "mount: document.getElementById(\"w-" <> showT idx <> "\")"
                   ]
        obj = "{" <> Text.intercalate ",\n" attrs <> "}"
        rs = "if (onWindowResize[" <> showT idx <> "]) {onWindowResize[" <> showT idx <> "]" <> showT (w, h) <> "}; "
     in "windows[" <> showT idx <> "] = (new WinBox(" <> from (show title) <> ", " <> obj <> ")); " <> rs

withWID :: WinID -> Text -> Text
withWID winID n = n <> "-" <> showT winID

withoutWID :: TriggerName -> TriggerName
withoutWID (TriggerName n) = TriggerName $ Text.dropWhileEnd (== '-') . Text.dropWhileEnd isDigit $ n

wid_ :: WinID -> Text -> _
wid_ wid n = id_ (withWID wid n)

scopeTriggers :: WinID -> [TriggerName] -> [TriggerName]
scopeTriggers winID = map (\(TriggerName tn) -> TriggerName (withWID winID tn))

newGuiAppWin :: WinID -> ProgramName -> Maybe (TVar (Int, Int)) -> DrawHtml -> [TriggerName] -> (GuiApp -> ProcessIO ()) -> ProcessIO GuiApp
newGuiAppWin wid name size draw triggers = newGuiApp name size newDraw (scopeTriggers wid triggers)
  where
    newDraw client = do
        content <- draw client
        pure $ with div_ [id_ (withWID wid "w")] content

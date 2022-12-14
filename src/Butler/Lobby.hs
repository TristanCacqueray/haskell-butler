module Butler.Lobby (lobbyProgram) where

import Data.IntMap.Strict qualified as IM
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text

import Butler.Clock
import Butler.Desktop
import Butler.Display
import Butler.GUI
import Butler.Memory
import Butler.Prelude
import Butler.Session
import Butler.Storage
import Butler.User
import Butler.WebSocket
import Butler.Window

import Butler.App.Chat

data Lobby = Lobby
    { desktops :: MVar (Map Workspace DesktopStatus)
    , desktopsList :: MemoryVar [Workspace]
    }

data DesktopStatus = DesktopOffline | DesktopRunning Desktop

type Xinit = Desktop -> ProcessIO ()

newLobby :: ProcessIO Lobby
newLobby = do
    (savedList, desktopsList) <- newProcessMemory "desktops.bin" (pure mempty)
    let initialMap = Map.fromList $ map (\name -> (name, DesktopOffline)) savedList
    Lobby <$> newMVar initialMap <*> pure desktopsList

lobbyProgram :: AppLauncher -> Xinit -> ChatServer -> Display -> ProcessIO OnClient
lobbyProgram appLauncher xinit chat display = do
    dm <- newLobby
    displayProcess <- getSelfProcess
    dmProcess <- spawnProcess "welcome-desktop" do
        void $ awaitProcess displayProcess
    rootOS <- asks os
    let dmEnv = ProcessEnv rootOS dmProcess

    let getDesktop :: Workspace -> ProcessIO Desktop
        getDesktop name = modifyMVar dm.desktops $ \wss -> case Map.lookup name wss of
            Just (DesktopRunning desktop) -> pure (wss, desktop)
            _ -> do
                desktopMVar <- newEmptyMVar
                let desktopID = "desktop-" <> from name
                os <- asks os
                desktopStorage <- scopeStorage os.storage (from desktopID)
                void $ spawnProcess (ProgramName desktopID) $ local (#os . #storage .~ desktopStorage) do
                    startDesktop desktopMVar appLauncher xinit display name

                desktop <- takeMVar desktopMVar
                atomically $ modifyMemoryVar dm.desktopsList (name :)
                pure (Map.insert name (DesktopRunning desktop) wss, desktop)

    pure \case
        Workspace "" -> pure (dmEnv, lobbyHandler dm chat)
        name -> do
            desktop <- getDesktop name
            pure (desktop.env, desktopHandler appLauncher desktop)

chatWin :: WinID
chatWin = WinID 0

lobbyHandler :: Lobby -> ChatServer -> DisplayEvent -> ProcessIO ()
lobbyHandler dm chat = \case
    UserConnected "htmx" client -> do
        spawnPingThread client
        sendHtml client (with div_ [id_ "display-root"] (splashHtml "Loading..."))
        sleep 100
        sendHtml client (with div_ [id_ "display-root"] (splashHtml "Getting workspaces..."))
        sleep 60
        wss <- readMVar dm.desktops
        chatChan <- atomically (newChatReader chat)
        sendHtml client (lobbyHtml wss (renderChat chatWin chat client))
        spawnThread_ $ forever do
            ev <- atomically (readTChan chatChan)
            sendHtml client (updateChat chatWin client ev)
        handleClientEvents client $ handleLobbyEvents dm chat client
    _ -> pure ()

lobbyWsListHtml :: Map Workspace DesktopStatus -> HtmlT STM ()
lobbyWsListHtml wss =
    with div_ [id_ "ws-list", class_ "grid auto-cols-auto w-96"] do
        forM_ (Map.toList wss) $ \(ws, desktopStatus) -> do
            with
                div_
                [ class_ "p-2 mt-4 bg-stone-300 rounded cursor-pointer relative"
                ]
                do
                    with div_ [class_ "flex justify-end absolute bottom-0 right-0"] do
                        with
                            i_
                            [ id_ "delete-ws"
                            , encodeVal [("ws", toJSON ws)]
                            , class_ "px-4 py-2 ri-focus-3-fill text-red-500"
                            , hxTrigger_ "click"
                            , wsSend
                            ]
                            mempty
                        with
                            button_
                            [ hxTrigger_ "click"
                            , wsSend
                            , id_ "enter-ws"
                            , encodeVal [("ws", toJSON ws)]
                            , class_ btn
                            ]
                            "enter"
                    table_ do
                        let attr :: Text -> HtmlT STM () -> HtmlT STM ()
                            attr k v =
                                tr_ do
                                    with td_ [class_ "text-right pr-1"] do
                                        toHtml k
                                        ":"
                                    with td_ [class_ "font-medium"] do
                                        v
                        attr "name" (toHtml ws)
                        case desktopStatus of
                            DesktopOffline -> "offline"
                            DesktopRunning desktop -> do
                                clients <- lift (getClients desktop.clients)
                                attr "clients" do
                                    with div_ [class_ "flex"] do
                                        traverse_ (\c -> userIcon c.session.username) clients
                                wins <- IM.size . (.windows) <$> lift (readMemoryVar desktop.wm.windows)
                                attr "wins" (toHtml (show wins))

btn :: Text
btn = "rounded-none px-4 py-2 font-semibold text-sm bg-sky-500 text-white rounded-none shadow-sm"

lobbyHtml :: Map Workspace DesktopStatus -> HtmlT STM () -> HtmlT STM ()
lobbyHtml wss chat =
    with div_ [id_ "display-root"] do
        script_ "htmx.find('#display-ws').setAttribute('ws-connect', '/ws/htmx?reconnect=true')"
        splashHtml do
            with div_ [class_ "flex"] do
                with div_ [class_ "flex flex-col place-content-center pr-3"] do
                    with div_ [class_ "flex flex-col place-content-center mx-auto"] do
                        with div_ [class_ "items-center justify-center whitespace-nowrap"] do
                            "Welcome to "
                            with span_ [class_ "font-bold"] "ButlerOS"
                        with div_ [class_ "items-center justify-center grid"] do
                            img_ [src_ "/xstatic/favicon.ico"]
                    with div_ [class_ ""] do
                        chat
                with div_ [class_ "border border-2 mr-3"] mempty
                with div_ [class_ "flex-grow"] do
                    with div_ [class_ "flex flex-col place-items-center"] do
                        lobbyWsListHtml wss
                        with form_ [wsSend, hxTrigger_ "submit", class_ "mt-4 p-2 flex flex-col bg-stone-300 rounded w-96 relative", id_ "new-ws"] do
                            with (input_ mempty) [name_ "ws", type_ "text", placeholder_ "Workspace name"]
                            with select_ [name_ "flavor"] do
                                option_ "localhost"
                                option_ "quay.io/org/toolbox"
                            with (input_ mempty) [type_ "submit", class_ btn, value_ "create"]

handleLobbyEvents :: Lobby -> ChatServer -> DisplayClient -> TriggerName -> Value -> ProcessIO ()
handleLobbyEvents dm chat client trigger ev = case ev ^? key "ws" . _String of
    Just wsTxt -> do
        let ws = Workspace wsTxt
        logInfo "got welcome event" ["ws" .= ws, "trigger" .= trigger]
        case trigger of
            "delete-ws" -> modifyMVar_ dm.desktops $ \wss -> case Map.lookup ws wss of
                Just desktopStatus -> do
                    case desktopStatus of
                        DesktopRunning desktop -> void $ killProcess desktop.env.process.pid
                        DesktopOffline -> pure ()
                    let newWss = Map.delete ws wss
                    sendHtml client (lobbyWsListHtml newWss)
                    atomically $ modifyMemoryVar dm.desktopsList (filter (/= ws))
                    pure newWss
                Nothing -> do
                    logError "unknown ws" ["ws" .= ws]
                    pure wss
            "enter-ws" -> do
                sendHtml client do
                    with div_ [id_ "display-root"] do
                        script_ $ "window.location.pathname = \"/" <> wsTxt <> "\""
            "new-ws" -> do
                let cleanWS = Text.takeWhile (\c -> isAlphaNum c || c == '-') wsTxt
                case cleanWS of
                    "" -> logError "invalid ws" ["ws" .= cleanWS]
                    _ -> do
                        sendHtml client do
                            with div_ [id_ "display-root"] do
                                script_ $ "window.location.pathname = \"/" <> cleanWS <> "\""
            _ -> logError "unknown welcome event" ["ev" .= ev]
    Nothing -> case ev ^? key "message" . _String of
        Just msg ->
            atomically $ addUserMessage chat (MkMessage client.session.username msg)
        Nothing -> logError "missing ws" ["ev" .= ev]

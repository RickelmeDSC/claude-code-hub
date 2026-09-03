# ChText.ps1 - user-facing strings.
#
# The panel ships in English and Portuguese. The language is picked from the
# console culture unless config.json says otherwise, so the author keeps the
# tool in Portuguese while everyone else gets English out of the box.

function Initialize-ChText {
    param([string]$Lang = '')

    # Reading config.json here, instead of taking the language from the config
    # module, keeps ChText dependency-free. It also means `ch --help`, which
    # never loads the repository module, still honours the setting.
    if ([string]::IsNullOrWhiteSpace($Lang) -or $Lang -eq 'auto') {
        $cfg = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
        if ([System.IO.File]::Exists($cfg)) {
            try {
                $j = ConvertFrom-Json ([System.IO.File]::ReadAllText($cfg))
                if ($j.PSObject.Properties.Match('Language').Count -and $j.Language) { $Lang = [string]$j.Language }
            } catch { }
        }
    }
    if ([string]::IsNullOrWhiteSpace($Lang) -or $Lang -eq 'auto') {
        $Lang = 'en'
        try {
            if ((Get-Culture).Name -like 'pt*') { $Lang = 'pt' }
        } catch { }
    }
    $Lang = $Lang.ToLowerInvariant()
    if ($Lang -ne 'pt') { $Lang = 'en' }
    $global:ChLang = $Lang

    $en = @{
        colRepo = 'REPOSITORY'; colBranch = 'BRANCH'; colSess = 'SESS'; colWhen = 'ACTIVITY'
        archived = 'archived'; otherPlaces = 'other places with history'
        nothingFound = 'nothing here'; nothingMatches = "nothing matches '{0}'"
        escClears = 'Esc clears'
        kNavigate = 'navigate'; kOpen = 'open'; kRepoFilter = 'repo'; kSearch = 'search sessions'
        kReload = 'reload'; kQuit = 'quit'; kMove = 'move'; kSessions = 'sessions'
        secSessions = 'SESSIONS'; secMemory = 'MEMORY'; noSessions = 'no conversation recorded here yet'
        noClone = '(not cloned locally)'
        gitChanged = '{0} changed'; gitAhead = '{0} to push'; gitBehind = '{0} to pull'
        gitNoUpstream = 'no upstream'; gitClean = 'clean'
        kResume = 'resume'; kNew = 'new'; kContinue = 'continue'; kMemory = 'memory'
        kFolder = 'folder'; kEditor = 'VS Code'; kEditorShort = 'code'; kGitHub = 'GitHub'; kBack = 'back'
        stNoSession = 'nothing to resume here - press n to start a conversation'
        stGoneDir = "that session's directory no longer exists"
        stNoCloneClone = 'not cloned - go back and press Enter to clone it'
        stNoClone = 'not cloned locally'; stNoMemory = 'this project has no memory yet'
        stOpenedBrowser = 'opened in the browser'; stNoGitHub = 'this entry has no GitHub page'
        stOpenedFolder = 'opened the folder'; stNoFolder = 'no local folder to open'
        stNoCode = "the VS Code 'code' command is not on PATH"; stOpenedCode = 'opened in VS Code'
        stReloading = 'reloading...'; stUpdated = 'updated'; stCloned = 'cloned'
        memTitle = 'MEMORY'; memEntries = '{0} entries'; kRead = 'read'
        pagerLines = '  line {0}-{1} of {2}'; kScroll = 'scroll'
        searchTitle = 'SEARCH SESSIONS'; searchOf = '{0} of {1}'; searchText = 'text: '
        searchEmpty = 'nothing matches that text'; searchType = 'type to filter'
        cloneTitle = 'Clone {0}'; cloneInto = '  into {0}'; cloneConfirm = 'Confirm? [y/N] '
        cloneYes = 'y'; cloneDone = 'Done.'; cloneFailed = 'The clone failed.'
        anyKey = 'Press any key...'; anyKeyBack = 'Press any key to return to the panel...'
        claudeFailed = 'Could not start Claude: {0}'
        needTty = 'The panel needs an interactive terminal.'
        tooSmall = '  The window is too small for the panel.'
        tooSmallHint = '  Enlarge the terminal (minimum 54x14) or press q.'
        homeLabel = '~ (home folder)'
        noConversation = '(no conversation)'; noTitle = '(untitled)'
        offline = 'offline'
        dToday = 'today'; dYesterday = 'yesterday'
        hTag = '- Claude Code repositories, sessions and memory'
        hCh = 'open the repository you are in, or the list'
        hChText = 'open the list already filtered'
        hList = 'force the full list, even inside a repository'
        hSearch = 'search your conversations, across every repo'
        hReindex = 'drop the caches and rebuild'
        hSelftest = 'run the self-test'
        hPreview = 'draw the screens without interactive mode'
        hDiag = 'show the module paths and test loading'
        hHelp = 'this help'
        hInPanel = 'In the panel:'
        hMarkers = 'Next to the name, the marker means:'
        hMarkerLine = 'v  cloned and in sync     ^  something unsynced     .  not cloned locally'
        hConfig = 'Configuration:'
        msgDropped = '  caches dropped, rebuilding...'
        msgRebuilt = '  {0} sessions, {1} repositories in {2}s'
        offNoGh = 'gh was not found on PATH'
        offNoAnswer = 'gh did not answer (network or token)'
    }

    $pt = @{
        colRepo = 'REPOSITORIO'; colBranch = 'BRANCH'; colSess = 'SESS'; colWhen = 'ATIVIDADE'
        archived = 'arquivado'; otherPlaces = 'outros locais com historico'
        nothingFound = 'nada encontrado'; nothingMatches = "nada casa com '{0}'"
        escClears = 'Esc limpa'
        kNavigate = 'navegar'; kOpen = 'abrir'; kRepoFilter = 'repo'; kSearch = 'buscar sessao'
        kReload = 'recarregar'; kQuit = 'sair'; kMove = 'mover'; kSessions = 'sessoes'
        secSessions = 'SESSOES'; secMemory = 'MEMORIA'; noSessions = 'nenhuma conversa registrada aqui ainda'
        noClone = '(sem clone local)'
        gitChanged = '{0} alterado(s)'; gitAhead = '{0} a enviar'; gitBehind = '{0} a receber'
        gitNoUpstream = 'sem upstream'; gitClean = 'limpo'
        kResume = 'retomar'; kNew = 'nova'; kContinue = 'continuar'; kMemory = 'memoria'
        kFolder = 'pasta'; kEditor = 'VS Code'; kEditorShort = 'code'; kGitHub = 'GitHub'; kBack = 'voltar'
        stNoSession = 'nao ha sessao para retomar - use n para comecar uma'
        stGoneDir = 'o diretorio dessa sessao nao existe mais'
        stNoCloneClone = 'sem clone local - volte e use Enter para clonar'
        stNoClone = 'sem clone local'; stNoMemory = 'esse projeto ainda nao tem memoria'
        stOpenedBrowser = 'abri no navegador'; stNoGitHub = 'esse item nao tem pagina no GitHub'
        stOpenedFolder = 'abri a pasta'; stNoFolder = 'sem pasta local para abrir'
        stNoCode = 'o comando code do VS Code nao esta no PATH'; stOpenedCode = 'abri no VS Code'
        stReloading = 'recarregando...'; stUpdated = 'atualizado'; stCloned = 'clonado'
        memTitle = 'MEMORIA'; memEntries = '{0} registros'; kRead = 'ler'
        pagerLines = '  linha {0}-{1} de {2}'; kScroll = 'rolar'
        searchTitle = 'BUSCA NAS SESSOES'; searchOf = '{0} de {1}'; searchText = 'texto: '
        searchEmpty = 'nada casa com esse texto'; searchType = 'digite para filtrar'
        cloneTitle = 'Clonar {0}'; cloneInto = '  para {0}'; cloneConfirm = 'Confirma? [s/N] '
        cloneYes = 's'; cloneDone = 'Pronto.'; cloneFailed = 'O clone falhou.'
        anyKey = 'Pressione qualquer tecla...'; anyKeyBack = 'Pressione qualquer tecla para voltar ao painel...'
        claudeFailed = 'Nao consegui iniciar o Claude: {0}'
        needTty = 'O painel precisa de um terminal interativo.'
        tooSmall = '  A janela esta pequena demais para o painel.'
        tooSmallHint = '  Aumente o terminal (minimo 54x14) ou aperte q.'
        homeLabel = '~ (pasta pessoal)'
        noConversation = '(sem conversa)'; noTitle = '(sem titulo)'
        offline = 'offline'
        dToday = 'hoje'; dYesterday = 'ontem'
        hTag = '- repositorios, sessoes e memoria do Claude Code'
        hCh = 'abre o repositorio da pasta atual, ou a lista'
        hChText = 'abre a lista ja filtrada'
        hList = 'forca a lista, mesmo dentro de um repositorio'
        hSearch = 'busca nas suas conversas, em todos os repos'
        hReindex = 'descarta os caches e reconstroi'
        hSelftest = 'roda o auto-teste'
        hPreview = 'desenha as telas sem modo interativo'
        hDiag = 'mostra os caminhos dos modulos e testa o carregamento'
        hHelp = 'esta ajuda'
        hInPanel = 'No painel:'
        hMarkers = 'Ao lado do nome, o marcador quer dizer:'
        hMarkerLine = 'v  clonado e em dia       ^  tem coisa nao sincronizada  .  sem clone local'
        hConfig = 'Configuracao:'
        msgDropped = '  caches descartados, reconstruindo...'
        msgRebuilt = '  {0} sessoes, {1} repositorios em {2}s'
        offNoGh = 'gh nao encontrado no PATH'
        offNoAnswer = 'gh nao respondeu (rede ou token)'
    }

    if ($Lang -eq 'pt') { $global:T = $pt } else { $global:T = $en }

    # A missing key must never render as an empty line: fall back to English,
    # then to the key name itself, so a gap is visible instead of invisible.
    foreach ($k in $en.Keys) {
        if (-not $global:T.ContainsKey($k)) { $global:T[$k] = $en[$k] }
    }
    return $global:T
}

function Get-ChText {
    param([string]$Key)
    if (-not $global:T) { [void](Initialize-ChText) }
    if ($global:T.ContainsKey($Key)) { return $global:T[$Key] }
    return $Key
}

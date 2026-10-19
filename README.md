---
title: "GitHub Copilot + LiteLLM : demo locale pas a pas"
description: "Deployer et tester Ollama, LiteLLM, les cles individuelles, Copilot CLI et VS Code."
---

## Ce que vous allez montrer

Un modele open source Qwen 3 4B tourne sur votre machine avec Ollama.
LiteLLM expose une API compatible OpenAI et fournit une cle virtuelle distincte
pour chaque utilisateur. Copilot CLI et le Chat de VS Code appellent cette API.

```text
Copilot CLI / VS Code Chat
        |
        | cle virtuelle individuelle
        v
LiteLLM (127.0.0.1:4000) ---> PostgreSQL (cles et configuration)
        |
        v
Ollama (127.0.0.1:11434) ---> Qwen 3 4B, alias qwen3:4b-8k
```

Cette demo illustre une passerelle et des cles par utilisateur, pas un deploiement
centralise de la politique BYOK d'une entreprise GitHub. L'alias d'une cle est une
etiquette de demo, pas une preuve d'identite GitHub ou une integration SSO.
Grafana, les webhooks et les API d'administration GitHub ne font pas partie de cette stack.

> [!IMPORTANT]
> La configuration VS Code concerne le Chat BYOK. Elle ne remplace pas les
> suggestions de code inline de Copilot, la recherche semantique ou les embeddings.
> Le parcours VS Code reste a valider manuellement dans votre interface.

## 1. Verifier les prerequis

Utilisez un terminal PowerShell 7.4 ou plus recent, avec Docker Desktop demarre
en mode conteneurs Linux. Copilot CLI est necessaire pour le test CLI, VS Code
pour le parcours graphique. Prevoyez plusieurs Go de disque et de RAM disponibles.
Les poids du modele seuls representent environ 2,5 Go.

Si le depot est deja clone, placez-vous a sa racine. Pour un premier clone
du depot prive, authentifiez GitHub CLI avec votre compte autorise, puis lancez :

```powershell
gh repo clone Ch0wseth/copilot-litellm-demo
Set-Location .\copilot-litellm-demo
```

Verifiez les outils :

```powershell
$PSVersionTable.PSVersion
docker context show
docker info --format '{{.ServerVersion}}'
copilot --version
code --version
```

Sur Docker Desktop Windows, utilisez le contexte Linux pour ce terminal :

```powershell
$env:DOCKER_CONTEXT = 'desktop-linux'
```

Les commandes suivantes se lancent toutes depuis la racine du depot.
Gardez Docker Desktop ouvert pendant la demo.

## 2. Deployer la stack locale

```powershell
.\scripts\start-demo.ps1
```

Le premier lancement telecharge les images et le modele. Il peut prendre plusieurs
minutes selon le reseau et la machine. Le script genere `.env` s'il est absent,
demarre PostgreSQL et Ollama, cree l'alias `qwen3:4b-8k`, puis demarre LiteLLM.

Attendez le message :

```text
Demo ready: LiteLLM http://127.0.0.1:4000; Ollama http://127.0.0.1:11434
```

Verifiez ensuite :

```powershell
docker compose ps
docker compose exec -T ollama ollama list
```

Resultat attendu : trois services demarres, PostgreSQL `healthy`,
et le modele `qwen3:4b-8k` present dans Ollama.

Les API sont accessibles sur <http://127.0.0.1:4000> pour LiteLLM et
<http://127.0.0.1:11434> pour Ollama. PostgreSQL n'est pas publie sur l'hote.

> [!WARNING]
> `.env` contient la cle d'administration LiteLLM et les secrets PostgreSQL.
> Ne l'affichez pas pendant un partage d'ecran. Ne le commitez pas.
> Les anciennes cles utilisateur ne fonctionnent plus apres suppression du
> volume PostgreSQL : recreez-les a l'etape suivante.

## 3. Creer une cle individuelle sans l'afficher

Dans le meme terminal :

```powershell
$env:LITELLM_USER_KEY = .\scripts\new-user-key.ps1 -Alias demo-cli
```

Le script affiche une confirmation, mais la cle retournee est capturee directement
dans la variable d'environnement du terminal. Ne tapez pas cette variable seule :
cela afficherait le secret.

La cle est limitee au modele `qwen3:4b-8k`. Chaque execution cree une nouvelle cle.
Pour un second utilisateur, choisissez un autre alias et un autre terminal.
Une cle n'est pas un compte GitHub et son alias ne verifie pas l'identite du porteur.

Dans un nouveau terminal, recreez une cle ou saisissez une cle existante sans
l'inscrire dans l'historique :

```powershell
$env:LITELLM_USER_KEY = Read-Host 'Cle individuelle LiteLLM' -MaskInput
```

## 4. Executer les tests automatiques

Pour tester l'API uniquement :

```powershell
.\scripts\test-demo.ps1
```

Pour ajouter le test Copilot CLI :

```powershell
.\scripts\test-demo.ps1 -IncludeCopilot
```

Les controles doivent afficher `PASS` pour :

- La decouverte du modele avec la cle individuelle
- Le refus d'une cle invalide avec HTTP `401`
- Une reponse exacte `LITELLM_API_OK` du modele local
- Une reponse en streaming avec le marqueur et l'evenement final `[DONE]`
- Une reponse exacte `COPILOT_VIA_LITELLM_OK` si le test CLI est demande

Le script s'arrete en erreur si un controle echoue. Le test CLI desactive les
instructions personnalisees et les MCP integres pour limiter le contexte du
petit modele. Il ne valide ni une session agent complexe ni l'interface VS Code.
Le premier appel peut etre plus lent, car Ollama charge le modele en memoire.

### Verification realisee le 19 octobre 2026

Apres suppression puis recreation des images et des volumes Docker, les tests
de decouverte, refus de cle invalide, inference, streaming et Copilot CLI ont
tous reussi. Le test de revocation a aussi confirme HTTP `200` avant suppression
de la cle, puis HTTP `401` apres. Le parcours dans l'interface VS Code n'a pas
ete execute ; suivez l'etape 6 pour le valider sur votre installation.

## 5. Faire la demo dans Copilot CLI

Lancez un appel court :

```powershell
.\scripts\run-copilot-cli.ps1 --no-custom-instructions --disable-builtin-mcps --silent --prompt '/no_think Reply with exactly COPILOT_VIA_LITELLM_OK and nothing else. Do not use tools.'
```

Resultat attendu :

```text
COPILOT_VIA_LITELLM_OK
```

Puis ouvrez une session interactive :

```powershell
.\scripts\run-copilot-cli.ps1 --no-custom-instructions --disable-builtin-mcps
```

Exemple de prompt :

```text
/no_think Explique en trois phrases le role d'un proxy LiteLLM. N'utilise aucun outil.
```

Le lanceur configure le fournisseur uniquement pour le processus Copilot puis
restaure les anciennes variables du terminal. Ses reglages sont :

```text
COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:4000/v1
COPILOT_PROVIDER_TYPE=openai
COPILOT_PROVIDER_API_KEY=<cle individuelle, jamais la master key>
COPILOT_MODEL=qwen3:4b-8k
COPILOT_PROVIDER_MODEL_ID=gpt-4.1
COPILOT_PROVIDER_WIRE_MODEL=qwen3:4b-8k
```

`gpt-4.1` sert ici d'identifiant de compatibilite pour le client CLI.
Le modele demande a LiteLLM reste **Qwen 3**, pas GPT-4.1.
Les clients reservent 512 tokens de sortie dans les 8192 tokens de contexte :
le budget d'entree est donc de 7680 tokens.
Le lanceur limite les outils disponibles a `view`. Un modele local de 4B avec
8K de contexte n'est pas representatif des capacites des modeles Copilot heberges.
GitHub recommande au moins 128K de contexte pour les meilleurs resultats CLI.

## 6. Faire la demo dans VS Code

La configuration du CLI ne configure pas VS Code. Creez une deuxieme cle,
dans le terminal PowerShell, puis copiez-la dans le presse-papiers sans l'afficher :

```powershell
$vscodeKey = .\scripts\new-user-key.ps1 -Alias demo-vscode
Set-Clipboard -Value $vscodeKey
code .
```

Dans VS Code :

1. Ouvrez le Chat, puis la palette de commandes avec `Ctrl+Shift+P`.
2. Executez **Chat: Manage Language Models**.
3. Selectionnez **Add Models**, puis **Custom Endpoint**.
4. Donnez au groupe le nom `LiteLLM local` et au modele un nom explicite.
5. Collez la cle individuelle quand VS Code la demande, jamais la master key.
6. Choisissez **Chat Completions**, pas Responses ou Messages.
7. Dans le `chatLanguageModels.json` ouvert par VS Code, configurez le modele
   en suivant [le fichier de reference](vscode/chatLanguageModels.json).
   Conservez la reference `${input:...}` generee par VS Code pour votre cle,
   ou utilisez `${input:litellmApiKey}` et renseignez la cle a la demande.
8. Verifiez l'identifiant `qwen3:4b-8k` et l'URL complete
   `http://127.0.0.1:4000/v1/chat/completions`, puis enregistrez.
9. Revenez au Chat et selectionnez **Qwen 3 4B via LiteLLM** dans le selecteur
   de modeles. Si necessaire, redemarrez VS Code.
10. Dans un nouveau chat court, sans fichiers joints, envoyez le prompt suivant.

```text
/no_think Reply with exactly VSCODE_VIA_LITELLM_OK and nothing else.
```

Resultat attendu : `VSCODE_VIA_LITELLM_OK` dans le Chat et une requete
`POST /v1/chat/completions` reussie dans les logs LiteLLM.
Ne presentez le parcours VS Code comme valide qu'apres avoir observe ces deux elements.

Le fichier `vscode\chatLanguageModels.json` du depot est un exemple,
pas un parametre de workspace automatiquement charge.
Si vous utilisez une session avec le harness Copilot/Agent Host, la documentation
VS Code indique que `chat.agentHost.byokModels.enabled` doit etre active ;
cette integration est experimentale. Les politiques de votre organisation et la
version de VS Code peuvent aussi conditionner l'acces aux modeles.

Une fois la cle collee :

```powershell
Set-Clipboard -Value ''
Remove-Variable vscodeKey
```

## 7. Montrer que les requetes passent par LiteLLM

Ouvrez un deuxieme terminal a la racine du depot :

```powershell
docker compose logs --tail 30 -f litellm
```

Envoyez un prompt depuis Copilot CLI ou VS Code. Une requete reussie vers
`/v1/chat/completions` doit apparaitre. `Ctrl+C` arrete le suivi des logs,
pas les conteneurs. N'activez pas les logs debug pendant une presentation :
ils peuvent contenir des prompts ou d'autres donnees sensibles.

Cette observation confirme le passage par la passerelle. Elle ne constitue pas
une demo Grafana, un audit complet ou une garantie d'isolation reseau de tous les
composants du client. Les ports publies sont limites a la machine locale,
mais Ollama est directement accessible aux autres processus locaux.

## 8. Montrer la revocation d'une cle

Faites cette manipulation dans un terminal d'administration non partage.
Elle revoque la cle CLI de ce terminal, pas la cle VS Code creee separement.

```powershell
$masterKey = (Get-Content .env | Where-Object { $_ -match '^LITELLM_MASTER_KEY=' }) -replace '^LITELLM_MASTER_KEY=', ''
try {
    Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:4000/key/delete' `
        -Headers @{ Authorization = "Bearer $masterKey" } `
        -ContentType 'application/json' `
        -Body (@{ keys = @($env:LITELLM_USER_KEY) } | ConvertTo-Json) | Out-Null
} finally {
    Remove-Variable masterKey
}
$response = Invoke-WebRequest -Uri 'http://127.0.0.1:4000/v1/models' `
    -Headers @{ Authorization = "Bearer $env:LITELLM_USER_KEY" } -SkipHttpErrorCheck
[int]$response.StatusCode
```

Resultat attendu : `401`. Si la cle est encore acceptee, attendez l'expiration
du cache d'authentification du proxy avant de retester. Ne declarez pas la
revocation valide tant que l'API accepte la cle.

Recreez une cle pour poursuivre :

```powershell
$env:LITELLM_USER_KEY = .\scripts\new-user-key.ps1 -Alias demo-cli
```

## 9. Arreter et relancer sans perdre la demo

En fin de presentation :

```powershell
.\scripts\stop-demo.ps1
Remove-Item Env:\LITELLM_USER_KEY -ErrorAction SilentlyContinue
```

Les conteneurs s'arretent, les cles PostgreSQL et les poids Ollama restent dans
les volumes. Pour relancer :

```powershell
.\scripts\start-demo.ps1
$env:LITELLM_USER_KEY = .\scripts\new-user-key.ps1 -Alias demo-cli
.\scripts\test-demo.ps1 -IncludeCopilot
```

> [!CAUTION]
> `docker compose down --volumes` supprime les donnees de cette demo :
> les cles utilisateur et les modeles telecharges. Ce n'est pas une commande
> d'arret normal. Ne supprimez pas les volumes avant une presentation.

## Depannage

| Symptome                | Action                                                                     |
|-------------------------|----------------------------------------------------------------------------|
| Docker indisponible     | Demarrer Docker Desktop en mode Linux et verifier `docker context show`     |
| Port deja occupe        | Identifier le service qui utilise 4000 ou 11434, sans le tuer arbitrairement |
| Echec du demarrage      | Lire `docker compose logs --tail 60 litellm postgres ollama`                 |
| Modele absent           | Verifier `docker compose exec -T ollama ollama list`, puis relancer le script |
| HTTP 401                | Recreer une cle apres une remise a zero des volumes ou une revocation        |
| Reponse lente           | Laisser le premier chargement finir ; utiliser un prompt court sans fichiers |
| Contexte trop grand     | Nouveau chat, sans fichiers ; desactiver les instructions et MCP pour le CLI |
| Modele absent VS Code   | Verifier Custom Endpoint, l'URL, les politiques, puis redemarrer VS Code      |
| Ancienne cle VS Code    | Mettre a jour la cle du provider apres la recreation de la base PostgreSQL    |

Les tags d'images sont mobiles (`latest` et `main-stable`) : une nouvelle machine
peut recuperer une autre version. Refaites les tests apres une mise a jour.
Cette stack locale n'est pas durcie pour la production : pas de TLS ni de SSO,
et Ollama n'a pas d'authentification locale.

## References

- [Copilot CLI : ajouter un fournisseur BYOK](https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models)
- [VS Code : modeles BYOK et Custom Endpoint](https://code.visualstudio.com/docs/agent-customization/language-models)
- [LiteLLM : demarrage Docker](https://docs.litellm.ai/docs/proxy/docker_quick_start)
- [LiteLLM : cles virtuelles](https://docs.litellm.ai/docs/proxy/virtual_keys)
- [Ollama : compatibilite OpenAI](https://docs.ollama.com/api/openai-compatibility)

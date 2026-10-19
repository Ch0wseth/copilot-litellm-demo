---
title: "GitHub : compte technique et API d'administration"
description: "Choisir une identite d'automatisation et preparer une demonstration en lecture seule avec des permissions adaptees a chaque endpoint."
---

## Reponse courte

Oui, un compte dedie a l'automatisation peut appeler des API d'administration
s'il est autorise par votre gouvernance, possede le role requis et utilise un
type de jeton accepte par l'endpoint. Le simple nom de compte technique ne
confere aucun privilege : organisation owner, enterprise owner et
site administrator GHES sont des roles differents.

Pour une integration durable, privilegier une **GitHub App lorsque l'endpoint
l'accepte**, avec les permissions minimales et des jetons d'installation
temporaires. Ne pas promettre qu'une GitHub App remplace un compte administrateur
pour toutes les API. Certains endpoints restent documentes avec un PAT classic.

## Une demo est-elle utile

Oui : une demonstration en lecture seule peut montrer l'identite appelee,
le resultat d'un `GET`, le perimetre du jeton et le refus d'un acces non accorde.
Elle n'a pas besoin de Docker, de Copilot CLI ou de VS Code.
Le terminal integre de VS Code peut executer les memes commandes PowerShell,
mais ce n'est pas une integration Copilot.

Le meilleur scenario lie a Copilot est de lire le nombre de sieges d'une
organisation de test. Une seconde variante illustre une GitHub App limitee
a un depot, sans lui donner des droits administrateur d'entreprise.

> [!NOTE]
> Le script fourni ne cree ni compte technique, ni GitHub App, ni PAT.
> Les commandes sont a executer uniquement sur une cible explicitement approuvee.
> La lecture des droits du depot de cette demo a ete executee ; les appels
> de sieges et d'audit entreprise restent a executer avec les autorisations requises.

## Lancer la demo avec le script

Depuis la racine du depot, avec PowerShell 7.4 et GitHub CLI :

```powershell
# Utilise le compte gh courant (ou GH_TOKEN), sans changer son authentification.
gh auth status
.\admin-api\test-access.ps1 -Operation RepositoryAccess -Target Ch0wseth/copilot-litellm-demo

# Avec un compte autorise sur VOTRE organisation de test :
$org = Read-Host 'Organisation de test approuvee'
.\admin-api\test-access.ps1 -Operation OrganizationSeats -Target $org
```

`RepositoryAccess` affiche le nom du depot, sa visibilite et le droit admin
si GitHub le fournit. Il ne prouve pas des droits owner d'organisation.
`OrganizationSeats` affiche uniquement `total_seats`, sans affectations individuelles.
Une erreur API interrompt le script au lieu de retourner zero.

Pour utiliser un PAT du compte technique ou un jeton d'installation d'app deja
genere, ajouter `-PromptToken`. Le jeton est saisi masque, utilise uniquement
dans le processus puis l'ancien `GH_TOKEN` est restaure, meme en cas d'echec.
Sur GHES, le script utilise et restaure `GH_ENTERPRISE_TOKEN` a la place :

```powershell
.\admin-api\test-access.ps1 -Operation OrganizationSeats -Target $org -PromptToken
```

Le type de jeton et les permissions doivent correspondre a l'endpoint ; le script
ne genere pas une identite ni ne donne des droits a un compte. Ne pas saisir
un JWT d'app comme jeton d'installation.

Pour une entreprise autorisee :

```powershell
$enterprise = Read-Host 'Slug de l entreprise de test approuvee'
.\admin-api\test-access.ps1 -Operation EnterpriseSeats -Target $enterprise -PromptToken
.\admin-api\test-access.ps1 -Operation EnterpriseAudit -Target $enterprise -PromptToken
```

`EnterpriseAudit` demande au plus un evenement web et affiche seulement le
nombre retourne, pas l'evenement. Ces appels ne modifient rien. Ils ne testent
ni l'attribution de sieges ni toutes les pages d'un inventaire.

Tous les appels supportent `-GitHubHostname`. La valeur doit etre le nom d'hote
utilise par `gh` (par exemple `SUBDOMAIN.ghe.com` ou `ghes.example`),
pas l'URL `api.SUBDOMAIN.ghe.com` ni une URL avec `https://`.
Verifiez que l'operation existe sur ce produit ; les endpoints Copilot Cloud
ne deviennent pas disponibles sur GHES par simple changement d'hote.
Les scripts utilisent la version REST `2022-11-28`, compatible avec ces appels.

Ne pas utiliser `GH_DEBUG=api` : le helper refuse le mode debug afin d'eviter
de journaliser les donnees et secrets. Il ne change pas le compte actif,
ne cree aucun fichier de credential et n'ecrit aucune reponse brute sur disque.

Pour les tests hors ligne des commandes, sans appel GitHub :

```powershell
.\scripts\test-github-demos.ps1
```

## 1. Preciser quelle API doit etre automatisee

Avant de choisir un compte, relever le produit, l'URL, la methode HTTP, le
perimetre et l'operation attendue. Les API `/orgs/...`, `/enterprises/...` et
`/admin/...` ne sont pas interchangeables.

| Besoin                                  | Exemple d'endpoint                              | Identite et autorisation a verifier                     |
|-----------------------------------------|-------------------------------------------------|--------------------------------------------------------|
| Lire les sieges Copilot d'une organisation | `GET /orgs/{org}/copilot/billing/seats`         | Owner + PAT classic `read:org` ou `manage_billing:copilot` |
| Meme operation via une app               | Meme endpoint                                   | Jeton d'installation accepte ; permissions organisation |
| Lire les sieges Copilot d'une entreprise | `GET /enterprises/{enterprise}/copilot/billing/seats` | Owner ou billing manager ; PAT classic `read:enterprise` ou `manage_billing:copilot` |
| Lire l'audit log d'une entreprise Cloud  | `GET /enterprises/{enterprise}/audit-log`         | PAT classic `read:audit_log` avec role requis, ou app enterprise autorisee |
| Gerer les hooks globaux GHES             | `/admin/hooks`                                  | Site admin GHES ; PAT classic selon cette documentation |

Pour l'app lisant les sieges d'organisation, la fiche endpoint accepte au moins
un des deux jeux de permissions : **GitHub Copilot Business: read** ou
**Administration: read**. Privilegier la permission Copilot pour ce besoin ;
il n'est pas necessaire d'accorder les deux ni d'ajouter de l'ecriture.

Pour l'audit log enterprise, la section **Fine-grained access tokens** de la
fiche endpoint accepte aussi les jetons GitHub App avec
**Enterprise administration: read**. Le jeton doit correspondre a une app
installee au niveau entreprise avec cette permission. En revanche, cette fiche
exclut les PAT fine-grained. Ne pas confondre PAT fine-grained et jeton
d'installation d'app : une restriction du premier ne signifie pas que les
GitHub Apps sont toutes exclues. Le PAT classic reste une autre option documentee.

Les endpoints de gestion Copilot cites sont en public preview dans les pages
consultees. Confirmer leur contrat avant industrialisation et ne pas extrapoler
le support des sieges d'organisation aux sieges d'entreprise.

## 2. Choisir l'identite

### GitHub App

Une app fournit une identite d'integration independante du depart de son auteur.
Les appels avec un jeton d'installation sont attribues a l'app. GitHub indique
qu'une app ne consomme pas de licence utilisateur GitHub.

Son acces depend des permissions **et** de l'installation : une app possedee
par l'entreprise n'est pas automatiquement installee sur toutes ses organisations.
Certaines apps avec permissions enterprise peuvent etre installees sur
l'entreprise, mais cela ne rend pas toutes les API compatibles.

Le flux habituel est : cle privee de l'app dans un coffre, JWT d'app,
creation d'un jeton d'installation, puis appel de l'endpoint accepte.
Le jeton d'installation expire apres une heure ; la cle privee reste un secret
longue duree a proteger et a faire tourner.

### Compte dedie avec PAT

Si une API requiert une identite utilisateur, un compte dedie peut porter le PAT,
avec les roles necessaires, une expiration courte, une rotation et un responsable
identifie. Ne pas partager les identifiants de connexion entre operateurs.
Le PAT n'augmente jamais les droits de son proprietaire.

Pour une entreprise EMU, le cycle de vie du compte passe par l'IdP et SCIM ;
ne pas creer un compte personnel externe comme contournement. En environnement
SAML impose, un bot ou compte de service doit disposer de l'identite externe
necessaire. Conserver les controles SSO, 2FA et Conditional Access applicables.
Un PAT n'est pas une solution de contournement de ces controles.

Verifier aussi l'impact de licence du compte avec votre administrateur :
ne pas supposer qu'un compte utilisateur technique est gratuit.

## 3. Demo Copilot en lecture seule avec un compte autorise

Prerequis : PowerShell 7.4, `gh` installe, une organisation de test avec un
abonnement Copilot Business/Enterprise et un compte owner autorise.
Creer hors presentation un PAT classic avec `read:org`, ou utiliser
`manage_billing:copilot` si c'est le scope retenu par votre administrateur.
Appliquer les validations SSO et politiques PAT requises.

Les exemples suivants ciblent GitHub.com uniquement. Pour GHE.com ou GHES,
utiliser le nom d'hote et la documentation de votre environnement, sans envoyer
un jeton d'une instance vers une autre.

Ouvrir un terminal dedie et saisir le jeton sans l'inscrire dans l'historique.
Le bloc restaure l'ancien `GH_TOKEN`, sans modifier le compte stocke par `gh`.

```powershell
$org = Read-Host 'Organisation de test approuvee'
if ([string]::IsNullOrWhiteSpace($org)) { throw 'Organisation obligatoire.' }
$orgPath = [Uri]::EscapeDataString($org)
$previousToken = $env:GH_TOKEN
try {
    $env:GH_TOKEN = Read-Host 'PAT classic du compte dedie' -MaskInput
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { throw 'Jeton obligatoire.' }

    gh api --hostname github.com --method GET user --jq '{login: .login}'
    if ($LASTEXITCODE -ne 0) { throw 'Identification du compte impossible.' }

    gh api --hostname github.com --method GET `
        -H 'Accept: application/vnd.github+json' `
        -H 'X-GitHub-Api-Version: 2026-03-10' `
        "orgs/$orgPath/copilot/billing/seats?per_page=1" `
        --jq '{total_seats: .total_seats}'
    if ($LASTEXITCODE -ne 0) { throw 'Lecture des sieges Copilot refusee ou indisponible.' }
} finally {
    if ($null -eq $previousToken) {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:GH_TOKEN = $previousToken
    }
}
```

Resultat attendu : le login du compte dedie, puis un objet `total_seats`.
Le parametre `per_page=1` limite la reponse et le filtre ne montre aucun nom
d'utilisateur assigne. Le total provient du serveur, pas d'un comptage de la page.
Pour un inventaire complet, suivre toutes les pages ; ce test n'en produit pas un.
Ne pas exporter les affectations individuelles pendant une demo.

Un `200` sur `/user` prouve seulement que le jeton identifie un utilisateur.
Le `GET` administratif reussi sur la ressource attendue est la preuve utile.
Un echec du second appel n'est pas transforme en resultat vide ou en zero siege.

## 4. Variante GitHub App

1. Faire creer une app de test dans le bon perimetre avec les seules permissions
   necessaires. Pour une simple demonstration d'identite d'app, les metadonnees
   d'un depot selectionne suffisent ; cela ne prouve pas l'acces admin Copilot.
2. Installer l'app uniquement sur le depot de test ou sur l'organisation de test,
   selon le besoin. Faire accepter les permissions additionnelles si elles changent.
3. Avec un SDK officiel ou l'automatisation de votre coffre, obtenir un jeton
   d'installation a partir du JWT et de
   `POST /app/installations/{installation_id}/access_tokens`.
   Ne pas utiliser le JWT d'app comme jeton pour lire les sieges Copilot.
4. Pour prouver seulement le perimetre depot, appeler `GET /installation/repositories`.
5. Pour prouver le besoin Copilot, appeler explicitement
   `GET /orgs/{org}/copilot/billing/seats` avec le jeton d'installation autorise.
6. Montrer uniquement le total et les permissions accordees, jamais le jeton.
7. Verifier la perte d'acces apres revocation dans l'environnement de test.

Exemple minimal pour lire le perimetre d'un jeton d'installation deja genere :

```powershell
$previousToken = $env:GH_TOKEN
try {
    $env:GH_TOKEN = Read-Host 'Jeton installation app de test' -MaskInput
    if ([string]::IsNullOrWhiteSpace($env:GH_TOKEN)) { throw 'Jeton obligatoire.' }
    gh api --hostname github.com --method GET installation/repositories `
        --jq '{total_repositories: .total_count}'
    if ($LASTEXITCODE -ne 0) { throw 'Lecture du perimetre installation impossible.' }
} finally {
    if ($null -eq $previousToken) {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    } else {
        $env:GH_TOKEN = $previousToken
    }
}
```

Ce `GET` ne valide pas les droits administrateur. Le meme bloc peut appeler
l'endpoint Copilot de l'etape 3 en remplacant uniquement l'appel `gh api` ;
ne pas executer `GET /user` avec un jeton d'installation, qui ne represente pas
un utilisateur connecte.

Pour un test negatif, utiliser un second depot de test **prive**, existant et
explicitement exclu de l'installation, puis verifier que
`GET /repos/{owner}/{repo}` n'y donne pas acces. Un depot public ne convient pas
a ce test de confidentialite. Ce refus de perimetre ne prouve pas a lui seul
le role administrateur.

## 5. Diagnostiquer sans elargir les privileges

| Resultat | Verification                                                        |
|----------|---------------------------------------------------------------------|
| `401`    | Jeton invalide, expire ou type d'authentification incorrect            |
| `403`    | Permissions, role, politiques SSO/IP ou limite d'appels a examiner     |
| `404`    | Mauvais hote/slug, ressource masquee faute d'acces ou API non disponible |
| `422`    | Preconditions du produit, configuration ou parametres a verifier       |
| `200`    | Verifier aussi le perimetre et la forme de la reponse attendue          |

Ne pas conclure d'un `404` que la ressource n'existe pas, ni d'un `403` qu'il
faut donner `admin:enterprise`. Examiner la reponse et les headers sans afficher
le jeton, les donnees nominatives ni activer `GH_DEBUG=api` en presentation.

Les operations d'attribution de sieges peuvent etre facturees et celles de
retrait peuvent supprimer l'acces d'utilisateurs. Aucun exemple d'ecriture
de licence n'est necessaire pour repondre a la question d'authentification.
Les droits d'un `GITHUB_TOKEN` Actions standard ne remplacent pas un
administrateur d'entreprise.

## 6. Fin de demonstration et industrialisation

Revoquer les jetons temporaires, retirer l'installation de test si elle n'est
plus utile et verifier que les acces sont effectivement perdus. Conserver
les secrets exclusivement dans le coffre, pas dans le depot, un README,
un transcript de terminal ou un fichier de configuration VS Code.

Pour industrialiser, maintenir une matrice endpoint/type de jeton/permissions,
renouveler les jetons, appliquer une rotation des cles, gerer les limites API,
la pagination et les erreurs, et journaliser les operations sans secrets.
La decision compte technique ou app se prend sur cette matrice, pas sur une
permission generique appelee "admin API".

## Sources officielles

Documentation verifiee le 19 octobre 2026. Aucun compte ou role client n'a ete
modifie. Contenu prepare avec assistance IA, a relire avant diffusion.

- [Gestion des utilisateurs et sieges Copilot](https://docs.github.com/en/enterprise-cloud@latest/rest/copilot/copilot-user-management)
- [Endpoints acceptant les jetons d'installation GitHub App](https://docs.github.com/en/enterprise-cloud@latest/rest/authentication/endpoints-available-for-github-app-installation-access-tokens)
- [Permissions requises pour les GitHub Apps](https://docs.github.com/en/enterprise-cloud@latest/rest/authentication/permissions-required-for-github-apps)
- [Authentification d'une installation GitHub App](https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/authenticating-with-a-github-app/authenticating-as-a-github-app-installation)
- [Choisir une GitHub App ou un PAT](https://docs.github.com/en/enterprise-cloud@latest/apps/creating-github-apps/about-creating-github-apps/deciding-when-to-build-a-github-app)
- [Creer une app pour son entreprise](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-github-apps-for-your-enterprise/creating-github-apps-for-your-enterprise)
- [API du journal d'audit enterprise](https://docs.github.com/en/enterprise-cloud@latest/rest/enterprise-admin/audit-log)
- [Comptes techniques et SAML](https://docs.github.com/en/enterprise-cloud@latest/organizations/granting-access-to-your-organization-with-saml-single-sign-on/managing-bots-and-service-accounts-with-saml-single-sign-on)
- [Enterprise Managed Users et cycle de vie IdP](https://docs.github.com/en/enterprise-cloud@latest/admin/managing-iam/understanding-iam-for-enterprises/about-enterprise-managed-users)
- [Server 3.22 : API des hooks globaux](https://docs.github.com/en/enterprise-server@3.22/rest/enterprise-admin/global-webhooks)

# Migration SharePoint

Script PowerShell de migration de fichiers depuis un dossier local vers une bibliotheque SharePoint Online avec `PnP.PowerShell`.

Le script parcourt recursivement un dossier source, cree les dossiers manquants dans SharePoint, envoie les fichiers, journalise les operations et peut appliquer une politique optionnelle basee sur les extensions exclues de la synchronisation OneDrive.

Ce fichier sert de reference technique. Pour un deroule operationnel pas a pas, voir `SCENARIO.md`.

## Structure

```text
.
|-- main.ps1
|-- config.xml
|-- SCENARIO.md
|-- functions/
|   |-- Convert-ToSharePointRelativePath.ps1
|   |-- Ensure-PnPPowerShell.ps1
|   |-- Ensure-RemoteFolder.ps1
|   |-- Format-FileSize.ps1
|   |-- Get-RequiredValue.ps1
|   |-- Get-TenantBlockedExtensions.ps1
|   |-- Get-TenantSyncExcludedExtensions.ps1
|   |-- Initialize-Log.ps1
|   |-- Join-SharePointPath.ps1
|   |-- MigrationWorkflow.ps1
|   |-- New-MigrationInventory.ps1
|   |-- ProjectDatabase.ps1
|   |-- Write-Log.ps1
|   `-- Write-Step.ps1
|-- logs/
`-- projects/
```

## Prerequis

- PowerShell 7 obligatoire pour les workflows projet `-Inventory`, `-DeltaInventory`, `-CheckChanges`, `-Migrate` et `-Resume`.
- Module PowerShell `PnP.PowerShell`.
- Module PowerShell `PSSQLite` pour le mode projet avec base `.db`.
- Application Azure AD / Entra ID autorisee a acceder au site SharePoint.
- Certificat installe localement et associe a l'application.
- Droits suffisants sur la bibliotheque SharePoint cible.

Installation des modules si necessaire:

```powershell
Install-Module PnP.PowerShell -Scope CurrentUser
Install-Module PSSQLite -Scope CurrentUser
```

### Tests locaux

Les tests de securite et de reprise utilisent Pester et une base SQLite temporaire:

```powershell
Invoke-Pester .\tests\ProjectSafety.Tests.ps1
```

Ils ne se connectent pas a SharePoint et ne modifient aucun projet existant.

## Configuration

La configuration se fait dans `config.xml`.

```xml
<Configuration>
    <Authentication>
        <TenantId>...</TenantId>
        <ClientId>...</ClientId>
        <CertificateThumbprint>...</CertificateThumbprint>
    </Authentication>

    <Source>
        <LocalPath>C:\Chemin\Vers\Dossier</LocalPath>
    </Source>

    <Destination>
        <SiteUrl>https://contoso.sharepoint.com/sites/Projet</SiteUrl>
        <Library>Shared Documents</Library>
        <Folder>SousDossierOptionnel</Folder>
    </Destination>

    <Logging>
        <LogDirectory>.\logs</LogDirectory>
        <ConsoleMode>ProgressOnly</ConsoleMode>
        <FileMode>Verbose</FileMode>
        <ProgressEveryFiles>1000</ProgressEveryFiles>
        <ProgressEverySeconds>30</ProgressEverySeconds>
    </Logging>

    <Migration>
        <HashMode>SHA256</HashMode>
        <ParallelInventory>4</ParallelInventory>
        <MaxAttemptsPerFile>3</MaxAttemptsPerFile>
        <MaxTotalErrors>1000</MaxTotalErrors>
        <ParallelUploads>4</ParallelUploads>
        <AssumeDestinationEmpty>false</AssumeDestinationEmpty>
        <TreatTenantSyncExclusionsAsBlocked>false</TreatTenantSyncExclusionsAsBlocked>
        <IncludeHiddenItems>false</IncludeHiddenItems>
        <ProcessingBatchSize>1000</ProcessingBatchSize>
    </Migration>

    <Exclusions>
        <Files>
            <Pattern>*.tmp</Pattern>
            <Pattern>Thumbs.db</Pattern>
        </Files>
        <Folders>
            <Pattern>node_modules</Pattern>
            <Pattern>archive/*</Pattern>
        </Folders>
    </Exclusions>
</Configuration>
```

Champs importants:

- `Authentication.TenantId`: identifiant du tenant Microsoft 365.
- `Authentication.ClientId`: identifiant de l'application Entra ID.
- `Authentication.CertificateThumbprint`: empreinte du certificat utilise pour l'authentification.
- `Source.LocalPath`: dossier local a migrer.
- `Destination.SiteUrl`: URL du site SharePoint cible.
- `Destination.Library`: bibliotheque cible. Attention a utiliser le nom attendu dans l'URL SharePoint, par exemple `Shared Documents`.
- `Destination.Folder`: dossier cible optionnel dans la bibliotheque.
- `Logging.LogDirectory`: dossier de sortie des journaux.
- `Logging.ConsoleMode`: niveau d'affichage console. Valeurs: `Verbose`, `ProgressOnly`, `ErrorsOnly`, `Quiet`.
- `Logging.FileMode`: niveau d'ecriture dans le fichier log. Valeurs: `Verbose`, `ProgressOnly`, `ErrorsOnly`, `Quiet`. Valeur conseillee: `Verbose` pour conserver le detail complet.
- `Logging.ProgressEveryFiles`: ecrit une progression tous les N fichiers traites pendant la migration projet. `0` desactive ce declencheur.
- `Logging.ProgressEverySeconds`: ecrit une progression toutes les N secondes pendant la migration projet. `0` desactive ce declencheur.
- `Migration.HashMode`: mode de detection des modifications locales. Valeurs autorisees: `SHA256`, `Quick`, `None`.
- `Migration.ParallelInventory`: nombre d'empreintes de fichiers calculees simultanement pour `-Inventory` et `-DeltaInventory`, entre `1` et `16`. Valeur conseillee: `4`.
- `Migration.MaxAttemptsPerFile`: nombre maximum de tentatives d'upload par fichier. Mettre `0` pour desactiver la limite.
- `Migration.MaxTotalErrors`: nombre maximum d'erreurs pendant une execution de migration. Mettre `0` pour desactiver l'arret automatique.
- `Migration.ParallelUploads`: nombre d'uploads simultanes, entre `1` et `16`. Commencer avec `4`.
- `Migration.AssumeDestinationEmpty`: si `true`, ne controle pas l'existence distante avant chaque upload.
- `Migration.TreatTenantSyncExclusionsAsBlocked`: si `true`, traite les extensions exclues de la synchronisation OneDrive comme non migrables. Ces restrictions ne sont pas des interdictions d'upload SharePoint; l'option est desactivee par defaut et exige des droits d'administration tenant pendant l'inventaire.
- `Migration.IncludeHiddenItems`: si `true`, l'inventaire, le delta et le controle de changements utilisent aussi les fichiers caches/systeme. Les dossiers vides ne sont pas inventories comme elements separes.
- `Migration.ProcessingBatchSize`: taille des lots de hash et des pages de migration SQLite. Defaut: `1000`.
- `Exclusions.Files.Pattern`: motifs de fichiers a exclure. Les motifs sont compares au nom du fichier et au chemin relatif.
- `Exclusions.Folders.Pattern`: motifs de dossiers a exclure. Les motifs sont compares aux segments de dossiers et au chemin relatif du dossier.

## Utilisation rapide

Afficher l'aide integree:

```powershell
.\main.ps1 -Help
```

Lancement standard sans projet:

```powershell
.\main.ps1
```

Les journaux sont crees dans le dossier configure, par defaut `.\logs`.

Pour une migration repriseable, utiliser le workflow projet decrit ci-dessous.

## Affichage et logs

Pour les gros volumes, l'affichage d'une ligne par fichier peut ralentir la migration et rendre la console difficile a lire. Les modes de log se reglent dans `config.xml`.

Mode conseille pour la production:

```xml
<Logging>
    <LogDirectory>.\logs</LogDirectory>
    <ConsoleMode>ProgressOnly</ConsoleMode>
    <FileMode>Verbose</FileMode>
    <ProgressEveryFiles>1000</ProgressEveryFiles>
    <ProgressEverySeconds>30</ProgressEverySeconds>
</Logging>
```

Avec cette configuration, la console affiche les etapes, les erreurs, les avertissements importants, les lignes de progression et le resume final. Le fichier log conserve le detail complet, notamment les `[OK]` fichier par fichier.

Modes disponibles:

- `Verbose`: tout afficher/ecrire, comportement historique.
- `ProgressOnly`: masque les lignes fichier par fichier comme `[OK]` et `[SKIP]`, garde les etapes, progressions, erreurs et resumes.
- `ErrorsOnly`: ne garde que les erreurs.
- `Quiet`: n'affiche ou n'ecrit rien pour la cible concernee.

## Commandes essentielles

Workflow recommande:

```powershell
.\main.ps1 -NewProject -ProjectName "Migration-Lunii" -ConfigPath .\config.xml
.\main.ps1 -Project "Migration-Lunii" -Inventory
.\main.ps1 -Project "Migration-Lunii" -Status
.\main.ps1 -Project "Migration-Lunii" -Migrate
.\main.ps1 -Project "Migration-Lunii" -Resume
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

Lancements prudents sur gros volumes:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate -MaxFiles 20
.\main.ps1 -Project "Migration-Lunii" -Resume -MaxFiles 20
.\main.ps1 -Project "Migration-Lunii" -Resume -MaxFiles 1000
.\main.ps1 -Project "Migration-Lunii" -Resume
```

Controle et maintenance:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory -IncludeDeleted
.\main.ps1 -Project "Migration-Lunii" -Migrate -DeleteRemoteMissing
.\main.ps1 -Project "Migration-Lunii" -ResetFailed
.\main.ps1 -Project "Migration-Lunii" -PurgeReports -ReportRetentionDays 30
```

## Choisir la bonne commande

| Besoin | Commande |
| --- | --- |
| Creer un projet repriseable | `-NewProject -ProjectName "<nom>" -ConfigPath .\config.xml` |
| Construire l'inventaire initial | `-Project "<nom>" -Inventory` |
| Voir l'etat courant | `-Project "<nom>" -Status` |
| Migrer les fichiers en attente | `-Project "<nom>" -Migrate` |
| Reprendre apres erreur ou interruption | `-Project "<nom>" -Resume` |
| Tester une migration ou reprise sur un petit lot | `-Project "<nom>" -Migrate -MaxFiles 20` ou `-Resume -MaxFiles 20` |
| Voir les changements sans modifier la base | `-Project "<nom>" -CheckChanges` |
| Integrer les ajouts/modifications locaux | `-Project "<nom>" -DeltaInventory` |
| Integrer les suppressions locales | `-Project "<nom>" -DeltaInventory -IncludeDeleted` |
| Supprimer dans SharePoint les fichiers disparus localement | `-Project "<nom>" -Migrate -DeleteRemoteMissing` |
| Exporter les CSV | `-Project "<nom>" -ExportReport` |
| Rejouer les fichiers en erreur | `-Project "<nom>" -ResetFailed`, puis `-Migrate` ou `-Resume` |

## Workflow projet avec reprise

Le mode projet permet de rendre la migration repriseable apres un crash, une fermeture de session ou une erreur reseau. Chaque projet contient sa propre configuration, ses logs, ses rapports et une base SQLite `migration.db`.

Creation d'un projet:

```powershell
.\main.ps1 -NewProject -ProjectName "Migration-Lunii" -ConfigPath .\config.xml
```

Cette commande est obligatoire avant d'utiliser `-Project "Migration-Lunii"`. Si le projet n'existe pas encore, les commandes `-Inventory`, `-Migrate`, `-Resume`, `-Status` et `-ExportReport` ne peuvent pas le retrouver.

Cela cree:

```text
projects/
`-- Migration-Lunii/
    |-- project.json
    |-- config.xml
    |-- migration.db
    |-- logs/
    `-- reports/
```

Generation de l'inventaire dans la base `.db`:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Inventory
```

Inventaire delta, sans traiter les fichiers supprimes:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory
```

Inventaire delta en marquant aussi les fichiers supprimes:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory -IncludeDeleted
```

Migration avec suppression SharePoint des fichiers marques `MissingLocalFile`:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate -DeleteRemoteMissing
```

Controle des changements sans modifier les statuts:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
```

Controle des changements en listant aussi les fichiers supprimes:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges -IncludeDeleted
```

Migration depuis l'inventaire persistant:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate
```

Reprise apres interruption:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Resume
```

Reprise controlee sur un petit lot:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Resume -MaxFiles 20
```

Afficher l'etat courant:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Status
```

Exporter un rapport CSV:

```powershell
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

Cette commande genere quatre fichiers dans `reports/`:

- `migration_report_yyyyMMdd_HHmmss.csv`: detail de tous les fichiers de la table `Files`.
- `migration_summary_yyyyMMdd_HHmmss.csv`: resume par statut avec le nombre de fichiers et la taille totale.
- `migration_errors_yyyyMMdd_HHmmss.csv`: fichiers en erreur, uniquement `Failed` et `MissingLocalFile`.
- `migration_changes_yyyyMMdd_HHmmss.csv`: fichiers dont le hash a change entre deux inventaires.

Chaque `-Inventory` ou `-DeltaInventory` projet genere aussi `migration_blocked_extensions_yyyyMMdd_HHmmss_fff.csv`, y compris lorsque la liste est vide.

Controle apres migration:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory
.\main.ps1 -Project "Migration-Lunii" -ExportReport
```

Ce delta inventaire permet de detecter les fichiers nouveaux ou modifies localement pendant ou apres la migration. Par defaut, il ignore les fichiers supprimes. Ajouter `-IncludeDeleted` pour les marquer `MissingLocalFile`.

Pour etre iso avec la source locale, lancer ensuite:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate -DeleteRemoteMissing
```

Cette commande supprime dans SharePoint les fichiers marques `MissingLocalFile`, puis les passe en `DeletedRemote`.

Attention: `-CheckChanges` est uniquement un controle en lecture. Il genere un rapport mais ne met pas a jour `FileHash`, ne remet pas les fichiers modifies en `Pending` et ne prepare pas leur migration. Si `-CheckChanges` detecte un fichier `Modified`, executer ensuite:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory
.\main.ps1 -Project "Migration-Lunii" -Migrate
```

Apres ce delta et cette migration, un nouveau `-CheckChanges` ne doit plus remonter le fichier si le contenu local n'a pas encore change.

Si un fichier deja `Uploaded` ou `SkippedExists` a change, son hash ne correspond plus et le script le remet en `Pending`. `LastError` n'est pas utilise pour signaler ce cas: le changement est suivi par `HashChanged`, `PreviousFileHash`, `FileHash` et `LastHashChangedAt`.

Le rapport dedie est:

```text
migration_changes_yyyyMMdd_HHmmss.csv
```

Il contient les fichiers modifies detectes lors du dernier `-Inventory` ou `-DeltaInventory`:

```text
HashChanged = 1
```

Dans le rapport complet `migration_report_yyyyMMdd_HHmmss.csv`, filtrer:

```text
HashChanged = 1
```

Requete SQLite equivalente:

```sql
SELECT RelativePath, FullPath, Status, SizeBytes, LastWriteTimeUtc,
       PreviousFileHash, FileHash, LastHashChangedAt
FROM Files
WHERE HashChanged = 1
ORDER BY LastHashChangedAt DESC, RelativePath;
```

Purger les anciens rapports:

```powershell
.\main.ps1 -Project "Migration-Lunii" -PurgeReports -ReportRetentionDays 30
```

Remettre les fichiers `Failed` en `Pending`:

```powershell
.\main.ps1 -Project "Migration-Lunii" -ResetFailed
```

Statuts stockes en base:

- `Pending`: fichier pret a migrer.
- `Uploading`: tentative commencee, mais resultat final pas encore confirme dans SQLite.
- `Uploaded`: upload reussi.
- `Failed`: erreur lors de l'upload.
- `BlockedExtension`: extension exclue par la politique de migration active.
- `Excluded`: fichier ignore par un motif configure dans `Exclusions`.
- `SkippedExists`: fichier deja present dans SharePoint et non ecrase.
- `MissingLocalFile`: fichier present dans l'inventaire mais introuvable localement.
- `DeletedRemote`: fichier supprime de SharePoint avec `-DeleteRemoteMissing`.

Au lancement d'une reprise, les fichiers restes en `Uploading` conservent ce statut. Le script force alors un controle distant, meme avec `AssumeDestinationEmpty=true`, afin de ne pas reenvoyer aveuglement un fichier dont l'upload aurait reussi avant l'interruption.

Un verrou exclusif `migration.lock` empeche deux inventaires, migrations ou exports de travailler simultanement sur le meme projet.

Les fichiers d'un inventaire sont prepares avant toute modification de la table `Files`, puis appliques dans une transaction SQLite unique. Une erreur annule donc l'ensemble des changements de cet inventaire. L'application en base reutilise des commandes SQLite preparees et journalise la progression par lots `ProcessingBatchSize`.

## Base de donnees projet

Chaque projet contient une base SQLite:

```text
projects/<NomProjet>/migration.db
```

Cette base est la source de verite pour l'inventaire, la reprise et les rapports.

### Table `ProjectMetadata`

Stocke les informations generales du projet sous forme cle/valeur.

- `Key`: nom de l'information.
- `Value`: valeur associee.

Exemples:

- `ProjectName`: nom lisible du projet.
- `CreatedAtUtc`: date de creation du projet.
- `ConfigPath`: chemin du `config.xml` copie dans le dossier projet.

### Table `Files`

Table centrale de la migration. Une ligne correspond a un fichier local inventorie.

- `Id`: identifiant interne unique du fichier dans la base.
- `FullPath`: chemin complet du fichier local.
- `RelativePath`: chemin relatif depuis le dossier source. Sert a reconstruire l'arborescence SharePoint.
- `Extension`: extension normalisee du fichier, sans point.
- `FileHash`: hash SHA256 du fichier local au moment de l'inventaire. Sert a detecter les modifications locales entre deux inventaires.
- `PreviousFileHash`: hash precedent connu avant la derniere mise a jour du hash.
- `HashChanged`: vaut `1` si un changement de hash a ete detecte entre deux inventaires.
- `LastHashChangedAt`: date de derniere detection d'un changement de hash.
- `SizeBytes`: taille du fichier en octets.
- `LastWriteTimeUtc`: date de derniere modification locale au moment de l'inventaire.
- `TargetFolder`: dossier SharePoint cible.
- `TargetUrl`: URL serveur-relative complete du fichier cible SharePoint.
- `Status`: etat courant du fichier dans la migration.
- `StatusBeforeExclusion`: statut conserve lorsqu'un fichier passe temporairement en `Excluded`.
- `AttemptCount`: nombre de tentatives d'upload.
- `LastError`: derniere erreur connue pour ce fichier.
- `LastInventorySeenAt`: date du dernier inventaire ou le fichier a ete revu sur le disque.
- `CreatedAt`: date d'ajout de la ligne dans la base.
- `UpdatedAt`: date de derniere mise a jour de la ligne.
- `UploadedAt`: date d'upload reussi, si applicable.

Statuts possibles:

- `Pending`: fichier pret a etre migre.
- `Uploading`: fichier dont la tentative a commence sans resultat final confirme. A la reprise, son existence distante est verifiee avant toute nouvelle tentative.
- `Uploaded`: fichier envoye avec succes.
- `Failed`: erreur lors de l'upload.
- `BlockedExtension`: fichier bloque par la politique optionnelle basee sur les exclusions de synchronisation OneDrive.
- `Excluded`: fichier ignore par les exclusions de configuration.
- `SkippedExists`: fichier deja present dans SharePoint et non ecrase.
- `MissingLocalFile`: fichier present dans l'inventaire mais introuvable sur le disque au moment de la migration.
- `DeletedRemote`: fichier absent localement et supprime de SharePoint avec `-DeleteRemoteMissing`.

Quand l'inventaire est relance, la base n'est pas ecrasee:

- les nouveaux fichiers sont ajoutes;
- les fichiers existants sont mis a jour;
- les fichiers disparus du disque sont marques `MissingLocalFile`;
- les fichiers deja `Uploaded` ou `SkippedExists` restent dans ce statut si leur hash SHA256 n'a pas change;
- si un fichier deja migre a ete modifie localement, son hash change et il repasse en `Pending`;
- `HashChanged` est remis a `0` au debut d'un nouvel `-Inventory` ou `-DeltaInventory`, puis repasse a `1` uniquement pour les changements detectes pendant cette execution.

Modes de hash:

- `SHA256`: le plus fiable, lit le contenu complet du fichier.
- `Quick`: plus rapide, base la detection sur la taille et la date de derniere modification UTC.
- `None`: ne calcule pas de hash. La detection fine des modifications locales est desactivee.

### Table `Runs`

Trace les executions du projet.

- `Id`: identifiant interne de l'execution.
- `Mode`: type d'execution, par exemple `Inventory`, `Migrate` ou `Resume`.
- `StartedAt`: date de debut.
- `FinishedAt`: date de fin, si l'execution s'est terminee proprement.
- `Result`: resultat de l'execution, par exemple `Running`, `Success`, `PartialSuccess`, `Interrupted` ou `Failed`.
- `Message`: resume ou message d'erreur associe.

Cette table sert surtout a auditer les lancements et a comprendre l'historique d'un projet.

## Modes disponibles

Le script contient les options suivantes:

Une seule action principale peut etre demandee par lancement. Par exemple, `-Inventory -Migrate` est refuse au lieu de choisir silencieusement une action.

- `-WhatIf`: simuler les uploads et suppressions pour une migration ou reprise, sans modifier SharePoint.
- `-Help`: afficher l'aide integree.
- `-Overwrite`: autoriser l'ecrasement des fichiers existants.
- `-ParallelUploads`: surcharge le nombre d'uploads simultanes configure dans le XML.
- `-MaxFiles`: avec `-Migrate` ou `-Resume`, limite le nombre de fichiers traites pendant ce lancement. `0` signifie illimite.
- `-AssumeDestinationEmpty`: ignore le controle `Get-PnPFile` avant upload. A utiliser uniquement si la destination ne contient pas de fichiers externes au projet.
- `-Inventory`: generer uniquement un inventaire. Avec `-Project`, l'inventaire est stocke dans `migration.db`.
- `-DeltaInventory`: mettre a jour l'inventaire uniquement pour les fichiers nouveaux ou modifies.
- `-CheckChanges`: generer un rapport de changements sans modifier les statuts en base.
- `-IncludeDeleted`: avec `-DeltaInventory` ou `-CheckChanges`, traiter aussi les fichiers disparus.
- `-DeleteRemoteMissing`: avec `-Migrate` ou `-Resume`, supprimer dans SharePoint les fichiers marques `MissingLocalFile`.
- `-ConfigPath`: utiliser un autre fichier de configuration.
- `-NewProject`: creer un nouveau projet.
- `-ProjectName`: nom du projet a creer.
- `-Project`: nom ou chemin du projet existant.
- `-Migrate`: migrer les fichiers `Pending` depuis la base projet.
- `-Resume`: reprendre les fichiers `Pending`, `Failed` et `Uploading`.
- `-Status`: afficher le bilan de la base projet.
- `-ExportReport`: exporter les CSV de detail, resume par statut, erreurs et modifications.
- `-PurgeReports`: supprimer les rapports CSV plus anciens que `-ReportRetentionDays`.
- `-ReportRetentionDays`: nombre de jours a conserver lors de `-PurgeReports`. Defaut: `30`.
- `-ResetFailed`: remettre les fichiers `Failed` en `Pending`, remettre leur `AttemptCount` a `0` et vider `LastError`.
- `-ExcludeFile`: exclure des fichiers par motif, par exemple `-ExcludeFile *.tmp,Thumbs.db`.
- `-ExcludeFolder`: exclure des dossiers par motif, par exemple `-ExcludeFolder node_modules,archive/*`.

## Fonctionnement d'une migration

1. Charge toutes les fonctions du dossier `functions`.
2. Lit et valide les valeurs obligatoires de `config.xml`.
3. Initialise un fichier de log.
4. Verifie que le chemin source existe et correspond a un dossier.
5. Construit le chemin SharePoint cible.
6. Verifie et importe le module `PnP.PowerShell`.
7. Se connecte a SharePoint avec certificat.
8. Lit facultativement les exclusions de synchronisation OneDrive si la politique correspondante est active.
9. Valide que la bibliotheque ou le dossier SharePoint cible est accessible.
10. Parcourt tous les fichiers locaux en appliquant les exclusions.
11. Cree les dossiers distants manquants.
12. Verifie l'existence du fichier cible.
13. Upload le fichier ou l'ignore selon la configuration.
14. Ecrit un bilan final dans le log.

Certaines commandes projet ne suivent pas ce flux complet:

- `-NewProject` cree seulement la structure projet et la base SQLite.
- `-Status` lit uniquement la base projet.
- `-ExportReport` exporte les donnees de la table `Files`, un resume par statut, les erreurs et les modifications detectees.
- `-CheckChanges` lit la base et le disque local, puis genere un rapport sans connexion SharePoint et sans modifier les statuts.
- `-Migrate` et `-Resume` respectent `Migration.MaxAttemptsPerFile`, `Migration.MaxTotalErrors` et la limite optionnelle `-MaxFiles`.

## Inventaire

Le mode inventaire sert a analyser les fichiers sans effectuer d'upload.

Sans projet:

```powershell
.\main.ps1 -Inventory
```

Le script produit un journal dedie listant les fichiers bloques par la politique d'extensions active.

Avec projet:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Inventory
```

Le script alimente la base `migration.db`, notamment la table `Files`, avec le chemin local, le chemin relatif, la cible SharePoint, la taille, l'extension et le statut de chaque fichier.

Dans les deux cas, quand `Inventory` est actif, le script:

- se connecte a SharePoint;
- lit les exclusions de synchronisation OneDrive uniquement si la politique XML est active;
- valide la destination SharePoint;
- analyse les fichiers locaux;
- applique les exclusions;
- n'effectue aucun upload.

## Delta inventaire

Le delta inventaire sert a verifier uniquement ce qui a change depuis le dernier inventaire connu.

Commande standard:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory
```

Comportement:

- les nouveaux fichiers sont ajoutes en base;
- les fichiers dont le hash a change sont mis a jour;
- les fichiers modifies apparaissent dans `migration_changes_yyyyMMdd_HHmmss.csv` apres `-ExportReport`;
- les fichiers inchanges ne sont pas reecrits, seule leur date de dernier passage inventaire est mise a jour;
- les fichiers supprimes sont ignores par defaut.

Pour traiter aussi les suppressions:

```powershell
.\main.ps1 -Project "Migration-Lunii" -DeltaInventory -IncludeDeleted
```

Avec `-IncludeDeleted`, les fichiers presents en base mais absents du disque sont marques `MissingLocalFile`.

Pour synchroniser aussi les suppressions vers SharePoint:

```powershell
.\main.ps1 -Project "Migration-Lunii" -Migrate -DeleteRemoteMissing
```

Comportement:

- traite uniquement les fichiers deja marques `MissingLocalFile`;
- supprime le fichier correspondant dans SharePoint s'il existe;
- marque le fichier en `DeletedRemote` apres suppression ou s'il est deja absent de SharePoint;
- respecte `Migration.MaxAttemptsPerFile` et `Migration.MaxTotalErrors`;
- reste optionnel pour eviter les suppressions distantes accidentelles.

## Controle des changements

`-CheckChanges` sert a observer les changements sans preparer de migration.

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges
```

Comportement:

- compare les fichiers locaux avec les hash stockes en base;
- detecte les fichiers nouveaux;
- detecte les fichiers modifies si `HashMode` n'est pas `None`;
- ne modifie pas les statuts `Pending`, `Uploaded`, `SkippedExists`, etc.;
- ne se connecte pas a SharePoint;
- genere un rapport `migration_checkchanges_yyyyMMdd_HHmmss.csv`.

Pour inclure les suppressions dans ce rapport:

```powershell
.\main.ps1 -Project "Migration-Lunii" -CheckChanges -IncludeDeleted
```

## Exclusions

Les exclusions peuvent etre declarees dans `config.xml` ou passees en ligne de commande.

Exemples:

```powershell
.\main.ps1 -Inventory -ExcludeFile *.tmp,Thumbs.db -ExcludeFolder node_modules,archive/*
.\main.ps1 -Project "Migration-Lunii" -Inventory -ExcludeFile *.bak
```

Les motifs de fichiers sont compares au nom du fichier et au chemin relatif. Les motifs de dossiers sont compares aux segments du chemin et au chemin relatif du dossier.

## Ecrasement

Par defaut, si un fichier existe deja dans SharePoint, il est ignore.

Avec `-Overwrite`, le comportement est explicite: le script supprime le fichier cible existant avec `Remove-PnPFile -Force`, puis envoie le nouveau fichier avec `Add-PnPFile`.

## Limites d'erreurs

Les limites de migration sont configurees dans le `config.xml` du projet:

```xml
<Migration>
    <HashMode>SHA256</HashMode>
    <ParallelInventory>4</ParallelInventory>
    <MaxAttemptsPerFile>3</MaxAttemptsPerFile>
    <MaxTotalErrors>1000</MaxTotalErrors>
    <ParallelUploads>4</ParallelUploads>
    <AssumeDestinationEmpty>false</AssumeDestinationEmpty>
    <TreatTenantSyncExclusionsAsBlocked>false</TreatTenantSyncExclusionsAsBlocked>
    <IncludeHiddenItems>false</IncludeHiddenItems>
    <ProcessingBatchSize>1000</ProcessingBatchSize>
</Migration>
```

- `HashMode`: `SHA256`, `Quick` ou `None`.
- `ParallelInventory`: nombre de calculs d'empreinte simultanes pendant l'inventaire complet et le delta.
- `MaxAttemptsPerFile`: un fichier dont `AttemptCount` atteint cette valeur n'est plus rejoue. Un fichier `Uploading` reste toutefois controle a distance une derniere fois pour reconcilier un upload incertain.
- `MaxTotalErrors`: si ce nombre d'erreurs est atteint pendant une execution, la migration s'arrete.
- `ParallelUploads`: nombre d'uploads executes simultanement. Augmenter progressivement pour surveiller le throttling SharePoint.
- `AssumeDestinationEmpty`: supprime un appel distant par fichier, mais peut ecraser un fichier SharePoint non reference dans SQLite.
- `TreatTenantSyncExclusionsAsBlocked`: transforme explicitement les exclusions de synchronisation OneDrive en blocages de migration. Cette option ne decrit pas les restrictions natives d'upload SharePoint.
- `IncludeHiddenItems`: inclut les fichiers caches/systeme dans `-Inventory`, `-DeltaInventory` et `-CheckChanges`. Laisser `false` pour garder le comportement PowerShell standard.
- `ProcessingBatchSize`: taille des lots de hash et des pages de migration SQLite. L'enumeration locale complete reste chargee en memoire. `1000` convient a la plupart des migrations.

Dans un projet existant, modifier le fichier:

```text
projects/<NomProjet>/config.xml
```

## Logs

Les logs contiennent:

- demarrage et configuration utilisee;
- source locale;
- destination SharePoint;
- fichiers envoyes;
- fichiers ignores;
- fichiers bloques;
- erreurs detaillees par fichier;
- bilan final.

Exemples de statuts:

- `[INFO]`: information generale.
- `[WARN]`: avertissement ou fichier ignore.
- `[SUCCESS]`: upload reussi.
- `[ERROR]`: erreur bloquante ou erreur fichier.

## Depannage

### Certificat introuvable

Erreur typique:

```text
Cannot find certificate with this thumbprint in the certificate store.
```

Points a verifier:

- le thumbprint dans `projects/<NomProjet>/config.xml`;
- la presence du certificat dans le magasin Windows de l'utilisateur ou de la machine qui execute le script;
- l'execution depuis une session PowerShell ayant acces a ce magasin;
- les droits de l'application Entra ID associee au certificat.

### Extensions bloquees

`TreatTenantSyncExclusionsAsBlocked=true` lit les extensions exclues de la synchronisation OneDrive au niveau tenant et les traite comme une politique de migration.

Important: ces exclusions ne sont pas forcement des interdictions natives d'upload SharePoint. Si des fichiers passent en `BlockedExtension`, verifier le rapport:

```text
projects/<NomProjet>/reports/migration_blocked_extensions_yyyyMMdd_HHmmss_fff.csv
```

### Migration ou delta lent

Pour l'inventaire:

- `HashMode=SHA256` lit tout le contenu des fichiers et peut etre long;
- `HashMode=Quick` utilise taille + date de modification UTC et convient mieux aux gros tests;
- `ParallelInventory` augmente le nombre de calculs d'empreinte simultanes.

Pour l'application SQLite:

- la progression apparait sous la forme `Application delta SQLite: n/total`;
- `ProcessingBatchSize` controle la frequence de progression et la taille des lots;
- la transaction SQLite reste atomique: si elle echoue, le lot est annule.

Pour l'upload:

- `ParallelUploads` augmente le nombre d'uploads simultanes;
- augmenter progressivement pour surveiller le throttling SharePoint;
- utiliser `-MaxFiles` pour valider un lot avant une reprise complete.

### Reprise apres crash

Relancer:

```powershell
.\main.ps1 -Project "<NomProjet>" -Resume
```

Les fichiers restes en `Uploading` sont toujours reconciles a distance avant toute nouvelle tentative, meme si `AssumeDestinationEmpty=true`.

### Destination supposee vide

`AssumeDestinationEmpty=true` evite un controle distant par fichier et accelere la migration, mais le script ne verifie plus chaque cible avant upload. A utiliser uniquement si la bibliotheque cible ne contient pas de fichiers externes au projet.

## Precautions

- Verifier la destination SharePoint avant execution.
- Tester d'abord sur un petit dossier.
- Utiliser `-Overwrite` uniquement si l'ecrasement des fichiers existants est voulu.
- Ne pas partager `config.xml` publiquement: il contient des informations d'identification applicative.
- S'assurer que le certificat correspondant au thumbprint est installe sur la machine.
- Controler que le nom de bibliotheque correspond au chemin attendu par SharePoint.

## Verification rapide

Verifier la syntaxe du script principal:

```powershell
$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\main.ps1), [ref]$tokens, [ref]$errors) > $null
$errors
```

Verifier la syntaxe des fonctions:

```powershell
Get-ChildItem -Path .\functions -Filter *.ps1 | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) > $null
    $errors
}
```

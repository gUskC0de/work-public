# Granskning av migreringsskript

Datum: 2026-10-22. Status: föreslagna kodåtgärder genomförda lokalt; Windows- och migreringsverifiering återstår.

Kodgranskningen är statisk och gäller PowerShell-koden och README i repots rot.
Bedömningen har kompletterats med användarens System-, Application- och
Guestfs/Firstboot-loggar från en återställd Windows Server 2022-VM.
Ingen migrering, drivrutinsinstallation, registerändring eller nätverksändring har körts av agenten på macOS.
Samtliga åtta PowerShell-filer i repots rot har parserkontrollerats med PowerShell
7.7.0-preview.5 på macOS. PSScriptAnalyzer 1.25.0 har hämtats till en temporär katalog
för analys, utan global installation. Regressionstesterna använder mockade
Windows-kommandon och riktiga isolerade PowerShell-barnprocesser för argument- och
returkodstester. EXE-filen är oförändrad och har inte körts eller säkerhetsgranskats.

## Genomförda rättningar och verifiering

Alla tio ursprungliga fynd har fått en kodåtgärd. Firstboot-omprövningen nedan har
styrt den nya ansvarsfördelningen. De ursprungliga fyndtexterna och deras radnummer
bevaras längre ned som historik för versionen före rättningen; de är inte en lista
över kvarvarande fel i den ändrade versionen.

| Fynd | Genomförd åtgärd |
|---|---|
| 1. Avstängda kontroller och ovillkorlig avinstallation | Kontrollerna återaktiverade och anropas separat med felrapportering. Full avinstallerar aldrig Tools. |
| 2. WhatIf kunde avinstallera | Separat MSI-reparation skyddas före första mutation. WhatIf skriver inga återställningsfiler och kör inga ändrande native-kommandon. |
| 3. Fel gav framgång | Barnprocesser isoleras och returkoder förmedlas. Endast uttryckligen tillåtna varningskoder accepteras; blockerande fel stoppar fasen. |
| 4. RouteProtocol | Protocol används. Källinterface och active/persistent store bevaras, även för on-link-routes och andra next hops än default gateway. |
| 5. Flera kort | Alla kort exporteras och mappas via bevarad MAC eller explicit JSON-fil. Hela mappningen måste vara entydig före ändring. Routens källinterface styr vilket målkort som används. |
| 6. Fel state-katalog | Explicit StateDirectory stöds. Automatisk sökning använder fångsttid och datoridentitet över datum/suffix; osäker indata kräver explicit val. |
| 7. Inaktiverat kort | Ett unikt VirtIO-kort kan mappas trots Disabled, aktiveras och invänta adress/länk med tidsgräns. Flera möjliga kort gissas aldrig. |
| 8. Aggressiv cleanup | Radering av tjänster och produktregistrering borttagen. Endast explicit MSI-reparation med verifiering och tydliga fel-/omstartsresultat finns kvar. |
| 9. Win32_Product | Borttaget. Produktinventering läser avinstallationsregistret. |
| 10. Osignerad installer | Den medföljande filens oberoende jämförda SHA-256 är fast tillåten så menyval 2 fungerar utan extra flaggor. Andra osignerade filer kräver både uttrycklig switch och oberoende betrodd hash. Ogiltiga signaturer och explicit hashavvikelse blockeras. |

Dessutom genomfördes följande:

- Firstboot-spärr före efterstegets validering, nätverks-/diskändringar och separat
  Tools-reparation. Pågående eller okänd konvertering kan inte kringgås med
  FirstbootNotUsed; den flaggan gäller endast återställningsvägar utan Firstboot.
- Drivrutinsförberedelse finns kvar som standard. FirstbootManaged är ett uttryckligt
  alternativ för en verifierad återställningsväg, med varning om startdrivrutiner.
- Efter kollegans förtydligande återgår huvudskriptets Prepare till att stoppa och
  inaktivera de fyra Tools-tjänsterna som standard. Ursprunglig baseline sparas till
  fil före ändringen; saknad baseline eller fel vid stopp/inaktivering blockerar.
  Standalone-exporten är fortsatt skrivskyddad som standard. Källan avinstalleras
  aldrig; återgång till VMware använder original-VM och sparade tjänstelägen.
- Offlinefiler väljs relativt skriptet. Angivna arbets-/logg-/statuskataloger och DC-
  rapportkatalog respekteras. Online-läget använder det granskade lokala init-skriptet.
- Fel IP-prefix korrigeras. DNS-automatik, manuella DNS-servrar på DHCP-kort,
  tomma suffix, registreringsflaggor och föregående Disabled-status hanteras i rollback.
  IPv4-DNS ändras via det specifika IPv4-CIM-objektet.
- Diskreparation och borttagning av dolda kort kräver egna opt-in-switchar.
  Ett nyligen stoppat kritiskt nätverks-/applikationsservicefall göms inte bakom
  en generell lista över förväntade migrationsstopp.
- Tomma resultat från lyckade tjänste-/eventfrågor skiljs från misslyckade frågor.
  Systemkontroller för disk, filsystem och djupskanning rapporterar inte PASS efter
  ett konstaterat fel. Kontroll av arbetsgrupps-DNS använder ingen antagen publik domän.
- Drivrutinsbindningens native-returkoder och boot-startläge verifieras.
  Omstartskrav rapporteras separat. Den befintliga phantom-device-metoden behålls.
- PowerShell 5.1:s begränsning för booleska switchvärden vid `-File` undviks genom
  serialiserad parametersplatting i isolerade barnprocesser. Parametervärden blir
  inte exekverbar kod.
- README har uppdaterats på engelska med Firstboot-flöde, nya standardval,
  kompatibilitet med äldre exporter, reparationslägen, returkoder och testinstruktioner.

### Utförd verifiering

- **97 regressionstestfall godkända** i `tests/Test-MigrationLogic.ps1`.
  Testerna täcker Firstboot-status, datum/suffix/identitet för exporter, route-export,
  routeägarskap/beständighet, adapterval, WhatIf, MSI-fel, rollback, IP-prefix,
  DHCP/DNS-intention, tjänstejämförelser, diskmatchning, rapporter, signerarkrav,
  DC-roll, skydd av originalfiler vid staging och isolerade barnprocessers argument/returkoder.
- Det ursprungliga menyflödet 1/2/3 behålls. Steg 2 anropar redan exporten;
  inget separat exportsteg behövs. Prepare slutför export av flera NIC med en
  varning i stället för att kasta ett blockerande fel efter lyckad export.
  Steg 3 stöder nu flera kort: bevarad MAC används automatiskt, annars anges
  `-AdapterMappingPath` till huvudskriptet (samma meny) eller återställningsskriptet.
  Readiness rapporterar flera kort som varning med krav på mappning.
- Samtliga målkort och routes sparas före första nätverksändringen. Fel på kort två
  utlöser rollback av båda försöken i omvänd ordning; fel i en rollback hindrar inte
  försök på övriga kort. Tidigare format för ett kort kan fortfarande läsas.
  Nya testfall täcker omvänd ordning, ändrade MAC-adresser, sekundär route utan
  default gateway, ofullständig/dubbel mappning, ändrad målidentitet, snapshots och
  fel på det andra kortet. Detta är verifierat med mockar, inte på en Windows-VM.
- Parserkontroll av samtliga migreringsfiler utan parserfel.
- PSScriptAnalyzer med `tests/PSScriptAnalyzerSettings.psd1`: PowerShell 5.1-syntax
  och utvalda säkerhetsregler utan fynd. Den breda standardanalysen har också körts;
  den innehåller fortfarande bland annat befintliga stil-/namn-/positional- och
  WriteHost-varningar. Dessa har inte döljts genom att hävda en helt ren standardanalys.
- `git diff --check` används för diffkontroll.

### Installerarfil och ursprungligt Tools-flöde

Kollegans förklaring skiljer källans rollback från sanering på den återställda
Proxmox-kopian. Stoppa/inaktivera på källan är återställbart och återinförs som
standard i Prepare. Firstboot avinstallerar på mål-VM:en enligt de observerade
loggarna. Att radera tjänsteregistreringar efter misslyckad MSI-avinstallation
är ingen verifierad fullständig avinstallation; automatisk sc-delete-fallback
återinförs därför inte. Se [Microsofts beskrivning av sc delete](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/sc-delete).

Vid användarens körning av Prepare stoppade signaturkravet den medföljande
`virtio-win-guest-tools.exe` före installation. PE-filen anger version 0.1.271.0
och saknar inbäddad signatur. Den 2026-10-22 hämtades version 0.1.271-1 från
[projektets publiceringskälla](https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/archive-virtio/virtio-win-0.1.271-1/virtio-win-guest-tools.exe)
till en temporär katalog utan att köras. Binär jämförelse visade identiska filer;
båda hade SHA-256 `21a2c7d7607ca52de3d7f57b57c8ba8752b9ba68ca89b54de48ff266091b14e4`.
Användaren vill behålla vanligt menyflöde utan extra filundantag. Exakt denna hash
är därför fast tillåten när signaturstatus är NotSigned. Andra osignerade filer
kräver fortfarande explicit undantag och oberoende hash; ogiltiga signaturer och
explicit hashavvikelse blockeras. Binärens funktion/säkerhet är fortfarande inte
verifierad här. Nya tester läser den faktiska medföljande filen och verifierar
menyfasens standardbeteende, opt-out, WhatIf samt tjänstebaseline och felutfall.

### Returkod 259 i drivrutinsförberedelsen

Användarens Windows Server 2019-körning visade att pnputil lade till/identifierade
`oem14.inf` men returnerade 259. Min tidigare skärpning av returkodskontrollen
klassade det ovillkorligt som ett bindningsfel och stoppade Prepare före export
samt stopp/inaktivering av Tools. Installeraren och registerförberedelsen hade då
redan körts; ett stopp betyder inte att alla tidigare ändringar rullats tillbaka.

[Microsoft dokumenterar 259](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-return-values)
som att ingen enhet matchar eller att en bättre/nyare drivrutin redan används.
Hjälpskriptet accepterar nu 259 först efter kontroll av publicerat OEM-paket och
rätt original-INF via strukturerad DISM-inventering (`Get-WindowsDriver -Online`),
SYS-fil, boot-start och StartOverride. Ingen bekräftad hårdvarubindning antas;
den ska verifieras efter återställningen. Andra felkoder förblir blockerande.
Fem nya testfall täcker SCSI/Block, saknat/fel paket, misslyckad inventering,
saknad binär/startnyckel, felaktiga boot-inställningar samt 0/3010 och verkliga fel.
Windows-/SetupAPI-/DISM-anropen är mockade i den lokala verifieringen.

### PersistentStore utan protokollvärde och ofullständig route-export

Användarens nästa körning passerade drivrutinsförberedelsen men stoppade under
route-export. Jämförande Windows-diagnostik visade att ActiveStore hade normala
Protocol-värden, medan PersistentStore-posterna hade tomt anpassat Protocol och
råvärdet 65535. Där fanns route till 10.100.1.110/32 på interface 28 samt default-
routes på interface 18 och 14. Den tidigare kontrollen misstolkade detta och
kastade ett fel för den sparade posten utan aktiv motsvarighet. Därefter saknades
activeAdapters i den ofullständiga nätverksfilen.

Klassificeringen tar nu hänsyn till uttryckligen frågad PolicyStore. En sparad
route med null/tomt/65535-protokoll kan behandlas som beständig statisk route;
etablerade Local-/övriga protokoll skrivs inte över. Exporten anger protocolSource
så att klassificering via lagret kan skiljas från läst protokoll. Samma hantering
används i målets routeinventering och rollback-snapshots. ActiveStore-poster utan
känt protokoll och utan motsvarande PersistentStore-nyckel blockeras fortfarande.
[Microsoft beskriver lagren och kopieringen av sparade routes vid omstart](https://learn.microsoft.com/en-us/powershell/module/nettcpip/get-netroute?view=windowsserver2019-ps).

Routes ägs fortsatt av källinterface. Routen på interface 28 flyttas bara till det
mappade målkortet. Den sparade default-routen på interface 14 ligger utanför de
båda fångade aktiva korten och behålls för referens med uttrycklig varning; den
raderas inte och tilldelas inte ett annat kort automatiskt.

Routefel bevarar nu kortens information, markerar routeCaptureComplete=false och
ger ett blockerande exportresultat (52) före källans tjänsteändringar. Eftersteget
avvisar en uttryckligen ofullständig route-export och huvudskriptet ger ett tydligt
fel vid saknade kort/routes, även för äldre tomma JSON-objekt. Tom route-array är
fortsatt giltig; saknad eller null route-property är ofullständig indata.
Sju nya regressionstestfall täcker dessa felvägar, den observerade Windows-
varianten samt ägarskap, beständighet och målets snapshots. Windows-anropen är
mockade; rättningen behöver fortfarande provas på den aktuella Windows-VM:en.

### Fler NIC och stora routetabeller

Ingen gräns på två NIC eller fast antal routes finns i mappning/routehantering.
Ett nytt regressionstest kör åtta NIC och 800 statiska IPv4-routes, med omvänd
målordning, överlappande destinationsprefix mellan kort, olika next hops inklusive
on-link, metrik samt aktiva och beständiga poster. Testet verifierar export,
deduplicering, ägarskap och att samtliga 800 avsedda routeanrop går till rätt kort.
Lokala/DHCP-routes och en sparad route på ett icke fångat interface tilldelas inte
fel kort. Mappningen provas också med ändrade MAC-adresser på alla åtta korten.

Detta är logiktestning med mockade Windows-anrop, inte verifiering av faktisk
Windows-prestanda eller en genomförd stor migrering. Stödet avser fångade aktiva
källkort och statiska IPv4-routes. Avstängda/frånkopplade källkort, dynamisk routing,
IPv6, teaming och VLAN-/bridgekoppling kräver separat planering/verifiering.

### Firstboot-spärr och kvarlämnad balloon.log

Efter återläsningen visade användarens skärmbild Pending scripts: balloon.log.
Kontrollen räknade tidigare samtliga filer i scripts som väntande arbete. Detta
var ett fel i min spärr: installerarens loggfil är inget återstående skript.
Nu undantas .log-filer och deras namn exponeras separat som ignoredLogFiles.
Övriga filer blockerar fortfarande. En aktiv Firstboot-tjänst blockerar även med
slutmarkör, och utan tjänst krävs fortfarande complete eller sista lyckade
slutmeddelandet i log.txt. Skärmbilden ensam bevisar inte att Firstboot är färdigt.
Fyra nya regressionstestfall täcker kvarlämnad logg med båda slutbevisen, avsaknad
av slutbevis, aktiv tjänst och faktiska/okända skriptfiler. Samtliga 82 tester går
igenom med mockade Windows-servicefrågor och verkliga temporära filer.

### Firstboot-tjänster och diagnostik utan konsolkommandon

Nästa skärmbild visade Pending med tom lista över skript. Med den implementerade
logiken betyder det att en tjänst matchade spärren. Exakt tjänsteidentitet har
inte kunnat verifieras på mål-VM:en eftersom användaren inte kan klistra in
kommandon i konsolen. Den gamla sökvägsmatchningen fångar varje tjänst under
Guestfs/Firstboot och kan därmed även träffa installerad Balloon/QEMU Agent.
Libguestfs beskriver att [blnsvr.exe kan köras från Firstboot/Temp](https://libguestfs.org/virt-v2v-release-notes-2.12.1.html).

Tjänster vars verkliga körbara fil är blnsvr.exe eller qemu-ga.exe behandlas nu
som installerade payload-tjänster när tjänsten inte själv heter något med
firstboot. De redovisas separat i installedPayloadServices. En verklig
Firstboot-tjänst eller okänd tjänst under katalogen förblir blockerande även när
den är stoppad. En payloads filnamn i argument till en annan körbar fil räcker
inte för undantag. Slutmarkör/slutlogg och avsaknad av väntande skript krävs som
förut; ingen tjänst eller Firstboot-fil ändras av kontrollen.

Felmeddelandet listar nu blockerande tjänsters namn, status, startläge och
sökväg, väntande skript (eller none), slutmarkör och sista loggrad. Användaren
kan därför fotografera normal menyutdata utan extra felsökningskommandon.
Fem nya testfall verifierar payload-matchning, kvarvarande verklig tjänst,
okänd körbar fil, tjänstenamnets företräde och tydlig felutdata.

### Varningsklassificering efter avslutad Firstboot

Efter en ytterligare omstart visade användarens VM Firstboot status Complete.
Eftersteget laddade indata men stoppade före mappning/nätverksändringar eftersom
Test-CaptureCompleteness sökte efter Network configuration var som helst i
varningstexten. Formuleringen post-restore network configuration i den vanliga
varningen för flera NIC misstolkades därmed som ett fel i nätverksexporten.

Villkoret matchar nu exportens namnprefix (Network configuration: respektive
Raw network outputs:) i stället för beskrivningens ord. Varningar om flera NIC,
routes utanför fångsten och saknad BitLocker-inventering visas fortsatt som
varningar. Faktiska nätverks-/rådatafel förblir blockerande i Full/ApplyNetwork;
routeCaptureComplete=false och ofullständig nätverks-JSON spärras som tidigare.
Ett regressionstest med de tre observerade varningarna reproducerade felet före
ändringen. Alla 90 tester går nu igenom, inklusive blockerande exportfel och
skrivskyddad validering. Återställningsskriptets kodrevision är 2026-10-22.4.
Befintlig backup och fångst kan återanvändas; endast efterstegets kod behöver
uppdateras på den återställda VM:en för nytt test.

### Lagringskontroll efter fungerande nätverksåterställning

Användaren satte källans MAC-adresser på rätt Proxmox-NIC. Eftersteget kom då
igenom nätverksåterställningen. Skärmbilden visar matchad route 10.100.1.110/32,
DNS-flaggor och MAC för sekundärkortet samt svar från gateway 10.21.10.1. Disk,
filsystem, Guest Agent och VSS passerade. Slutstatus blev FAIL eftersom många
likadant namngivna VirtIO SCSI-enheter hade annan PnP-status än OK. Enhets-ID och
problemkod saknades i den äldre felutskriften, så typen av fel är ännu inte
bekräftad på VM:en. Upprepade Prepare-körningar kan skapa fler ROOT-hjälpenheter.

Lagringskontrollen är nu separat och redovisar InstanceId, status, problemkod och
hårdvaru-ID. Endast ROOT/VIOSCSI respektive ROOT/VIOSTOR med VirtIO-namn och
motsvarande preparerings-ID PCI VEN_1AF4 DEV_1004 respektive DEV_1001 klassas
som kända hjälpenheter. De ger en synlig varning, inte maskerad framgång. En
PCI-kontroller med samma namn, okänd ROOT-enhet eller ofullständigt verifierad
hjälpidentitet undantas inte från felkontrollen. Om endast hjälpenheter finns
rapporteras hårdvarukontrollen som NOT_CHECKED. Problemkod skild från noll ger
fel även om den sammanfattade statusen är OK. Inga enheter/tjänster/drivrutiner
raderas eller stoppas av kontrollen. Windows egenskaper läses med
[Get-PnpDeviceProperty](https://learn.microsoft.com/en-us/powershell/module/pnpdevice/get-pnpdeviceproperty).

Sju nya tester täcker många ROOT-enheter plus frisk PCI-kontroller, verkligt
PCI-fel, okänd ROOT-enhet, fel/saknade hårdvaruuppgifter, endast hjälpenheter,
Block/SCSI samt problemkoder och providerfel. Samtliga 97 tester och syntaxanalysen
passerar lokalt; faktisk klassificering behöver verifieras med ny Windows-utskrift.
Kodrevisionen är 2026-10-22.5. Efterkontrollernas FAIL återställer inte ett nätverk
som redan applicerats framgångsrikt. Nätverket kan lämnas orört vid nästa test
genom att starta Restore-And-TestMigrationState.ps1 utan parametrar (ValidateOnly).
Tjänstevarningar för bland annat RemoteAccess/RaMgmtSvc och förändrade lyssnarportar
behålls; eventuell routing-/VPN-funktion behöver verifieras separat.

### Kvarvarande verifiering före produktionskörning

Användarens Windows Server 2019-utskrift från 2026-10-22 kl. 15:54 visar att
Prepare nu slutförs med varningar: installerarhash, installation, boot-förberedelse
och export passerar. Källkortens aktuella interface är 19 respektive 6; en sparad
default-route via 10.145.60.161 på ej fångat interface 15 rapporteras för granskning.
VMware Tools rapporteras inte installerat, så tjänstestopp/återaktivering har inte
verifierats på denna VM. NetKVM-varningen kvarstår; inventeringen av PnP-enheter
bevisar inte om ett ännu obundet drivrutinspaket finns i Driver Store. Faktisk
VirtIO-bindning och nätverksåterställning ska verifieras på Proxmox efter Firstboot.
Den missvisande texten Manual removal required har ändrats till frivillig cleanup
av den tillfälliga ROOT-enheten. Ingen avinstallationsåtgärd krävs av det meddelandet.

Windows PowerShell 5.1 och verkliga Windows-CIM-, SetupAPI-, drivrutins-, VSS-,
MSI- och AD-anrop kan inte köras i denna macOS-miljö. Portabla tester och syntaxanalys
bevisar därför inte att migrering på en viss server är riskfri. En isolerad
återställning med er faktiska Veeam-/pluginversion behöver verifiera bootbarhet,
Firstboot-spärr, nätverk/routes efter omstart, diskar/applikationer och DC-hälsa där
relevant. Äldre exporter med Unknown-protokoll blockeras för automatiska ändringar;
gör en ny export eller konfigurera manuellt och validera. Exakt Veeam-/pluginversion
är ännu inte angiven. Inga ändringar har gjorts i Veeam eller dess Firstboot-skript.

## Ursprunglig granskning och Firstboot-omprövning

P1 = bör rättas innan produktionskörning. P2 = konkret fel eller risk som behöver
hanteras och provas innan berörda körfall används.

## Omprövning efter Firstboot-loggar

Den granskade återställningen kör sex separata Firstboot-skript: installation av
VirtIO-drivrutiner, väntan på Plug and Play, installation av QEMU Guest Agent,
installation av Balloon-tjänsten, avinstallation av VMware Tools och onlinesättning
av VirtIO-diskar. Sex omstartsbegäranden i System-loggen stämmer med detta flöde.
Inga omförsök syns i det levererade utdraget. Firstboot-tjänsten avinstalleras
framgångsrikt efter sista steget. Detta visar att Firstboot-sekvensen avslutats,
men bevisar inte att nätverk, applikationer eller alla enheter fungerar korrekt.

### Rekommendationer som ändras

- **Många omstarter är inte i sig ett fel i detta flöde.** Libguestfs dokumenterar
  omstarter mellan Firstboot-skript och virt-v2v 2.6 beskriver fyra eller fler
  omstarter efter Windows-konvertering. Rekommendationen att en omstart på
  VMware sannolikt skulle eliminera sekvensen dras tillbaka; den har inte
  verifierats och styr inte Firstboots egna omstartsbeslut.
- **Låt ett flöde äga drivrutiner, QEMU-agent, Tools-avinstallation och diskändringar.**
  I den observerade återställningen hanterar Firstboot redan dessa delar.
  Rekommendationen för det egna huvudflödet är därför att ta bort automatisk
  Tools-avinstallation och i första hand verifiera utfallet efter Firstboot.
  Egen sanering behövs endast som separat, uttryckligt reparationsflöde.
- **Tools kan redan vara avinstallerat före era efterkontroller.** Vårt tidigare
  förslag att alltid vänta med avinstallation tills alla egna kontroller är gröna
  kan inte genomföras enbart genom att ändra PowerShell-skripten. Det skulle också
  kräva en dokumenterad och stödd ändring av återställningens konvertering.
  Käll-VM och backup blir därför centrala för rollback; förlita er inte på att
  Tools finns kvar i den återställda kopian.
- **Förinstallation på VMware är ett villkorat behov.** Avgör detta utifrån exakt
  återställningsmetod, Veeam-/pluginversion och avsedd lagringskontroller. Den
  observerade Firstboot-installationen ersätter inte bevis på att den allra första
  uppstarten har rätt lagringsdrivrutin. Ta inte bort förberedelsen utan ett
  verifierat test av återställningsvägen. Om ett förberedelsesteg är obligatoriskt
  ska dess fel fortfarande stoppa flödet.
- **Lägg till en spärr före ValidatePost.** Bekräfta att Firstboot är färdigt och
  att ingen konverteringsomstart återstår innan egna nätverksändringar, diskändringar
  eller slutkontroller körs. Använd en slutmarkering som stöds av den installerade
  versionen tillsammans med logg-/statuskontroll; frånvaro av en tjänst eller
  tillgång till inloggningsskärmen räcker inte ensamt. En osäker eller misslyckad
  Firstboot-status ska ge ett tydligt stopp, inte starta ett konkurrerande flöde.
- **Behåll nätverksexporten och efterkontrollerna.** De sex listade skripten visar
  ingen explicit återställning av exporterad IP, DNS eller statiska routes.
  Faktisk målkonfiguration ska jämföras med exporten efter Firstboot, och ändras
  vid behov. Anta inte att all nätverkskonfiguration gått förlorad eller att den
  har återställts korrekt.

### Prioritering av tidigare fynd

Fynd 1 gäller fortfarande de avstängda efterkontrollerna. Tools-delen får en
ändrad åtgärd enligt ovan. Fynd 2, 8 och 9 gäller kvarvarande avinstallationskod;
den observerade automatiska vägen når normalt inte den farliga delen om Firstboot
redan tagit bort VMTools-tjänsten, men koden är fortfarande felaktig när Tools
finns kvar eller det separata avinstallationsläget används. Undvik att lägga
arbete på att förstärka automatisk dubbelavinstallation; ta bort överlappet.

Fynd 3–7 och 10 kvarstår: felpropagering, route-export, adaptermappning,
state-katalogval, hantering av inaktiverat kort och verifiering av installer påverkas
inte i sak av Firstboot. Installerfrågan gäller om den egna installationen behålls.

Firstboot-loggens Balloon-steg returnerar 1073, vilket betyder att tjänsten redan
finns. Steget markeras som färdigt. Det visar överlapp, inte i sig att Balloon
fungerar korrekt. Meddelandena om saknade registernycklar och enheter orsakar inga
synliga omförsök i utdraget; exakt orsak kräver inspektion av de genererade skripten.

Källor: [Firstboot och returkoder](https://www.libguestfs.org/virt-customize.1.html#firstboot),
[virt-v2v 2.6: Windows-omstarter](https://libguestfs.org/virt-v2v-release-notes-2.6.1.html),
[Microsoft: felkod 1073](https://learn.microsoft.com/en-us/windows/win32/debug/system-error-codes--1000-1299-).

Exakt Veeam-/pluginversion är ännu inte fastställd. Ingen inställning för att
hoppa över konvertering eller ändra Firstboot har verifierats för användarens miljö.

## 1. [P1] Full-läget avinstallerar Tools även när valideringen har misslyckats eller saknas

**Kod:** `Restore-And-TestMigrationState.ps1:1105–1124`.

Jämförelser av system, nätverk, diskar, roller, filsystem, händelser och
anslutningar är bortkommenterade på rad 1121. `-DeepScan` når inte heller sin
kontroll eftersom `Test-FilesystemAndEvents` inte anropas. Därefter anropas
avinstallationen ovillkorligt i Full-läge, innan summeringen beräknas.
Ett misslyckat adapterval eller felaktiga enhetsbokstäver stoppar inte detta.
DC-kontrollen körs dessutom först efter att återställningsskriptet har returnerat.

**Konsekvens:** flödet kan ta bort Tools utan att nätverk, applikationer eller
domänkontrollantens funktion har verifierats. README lovar att avinstallation
sker först efter godkänd validering, vilket koden inte uppfyller.

**Åtgärd efter Firstboot-fyndet:** återställ och verifiera kontrollerna och kör
dem efter avslutad Firstboot. Ta bort den automatiska Tools-avinstallationen ur
det egna Full-flödet när återställningen äger den uppgiften. Behåll eventuell
egen avinstallation som separat, uttryckligt reparationssteg med korrekta skydd.
En garanti om att Tools finns kvar tills egna kontroller är godkända kräver också
kontroll över återställningens Firstboot-sekvens; den garantin finns inte idag.

## 2. [P1] `-WhatIf` skyddar inte Tools-avinstallationen

**Kod:** `Restore-And-TestMigrationState.ps1:885–1017,1094–1096,1123`.

Skriptet annonserar `SupportsShouldProcess`, och README/kodexempel föreslår
`-Mode Full -WhatIf`. Funktionen `Remove-VMwareToolsUninstall` saknar dock
`ShouldProcess` runt avinstallationen. Native-anrop som `msiexec.exe`,
`sc.exe delete` och `reg export` är inte skyddade av PowerShells WhatIf.
Samma problem gäller läget `VmwareUninstall`.

**Konsekvens:** en förhandsgranskning kan faktiskt avinstallera Tools och
radera tjänster. Att vissa PowerShell-cmdlets ärver WhatIf räcker inte.

**Åtgärd:** skydda hela avinstallationsfunktionen med ett explicit
`$PSCmdlet.ShouldProcess(...)` före första sidoeffekten. Verifiera med mockade
native-kommandon att Full/VmwareUninstall + WhatIf inte startar någon mutation.

## 3. [P1] Huvudskriptet fortsätter efter blockerande fel och returnerar framgång

**Kod:** `Migrate-VmwareToProxmox.ps1:256–278,307–331,350–351`.

Alla icke-noll-returkoder behandlas som varningar. Om `mig_prep.ps1` exempelvis
returnerar 1 efter misslyckad drivrutinsinstallation körs exporten ändå.
Exporten stoppar/inaktiverar sedan VMware-tjänster. Fasen skriver därefter
`Prepare phase completed` och huvudskriptet avslutar med `exit 0`.
Även saknade beroendeskript hanteras med `return`, följt av framgång i huvudflödet.

**Konsekvens:** en server utan verifierad lagringsdrivrutin kan rapporteras som
färdig för migrering. Automatisering kan inte lita på huvudskriptets returkod.

**Åtgärd:** definiera accepterade varningskoder per delskript, stoppa på
blockerande fel och propag­era slutstatus. Testa särskilt drivrutinsfel, saknade
skript, exportfel och valideringsfel.

## 4. [P1] Fel egenskap gör att statiska routes inte klassificeras för återställning

**Kod:** `Export-MigrationState.ps1:306–323` och
`Restore-And-TestMigrationState.ps1:383,338,455–466`.

Exporten läser `RouteProtocol`. Den dokumenterade egenskapen på
`MSFT_NetRoute` heter `Protocol`. För normala route-objekt blir exportens
protokoll därför `Unknown`, vilket gör `isPersistentOrStatic` falskt.
Återställningen filtrerar sedan på just denna flagga och hoppar över routes.
Även rollback-koden använder det felaktiga egenskapsnamnet och förlorar
distinktionen mellan lokala och andra routes.

**Konsekvens:** IP, DNS och default gateway kan återställas medan trafik till
andra nät ändå slutar fungera.

**Åtgärd:** använd `Protocol` konsekvent, hantera `Local` respektive `NetMgmt`
och spara/återställ relevant route store. Prova en extra statisk route och
verifiera trafik samt beständighet efter omstart.

Källa: [Microsoft: MSFT_NetRoute](https://learn.microsoft.com/en-us/windows/win32/fwp/wmi/nettcpipprov/msft-netroute).

## 5. [P2] Flera nätverkskort exporteras men inget av dem återställs automatiskt

**Kod:** `Export-MigrationState.ps1:493–495` och
`Restore-And-TestMigrationState.ps1:249–269`.

Exporten och användarmeddelandena lovar automatisk återställning av det första
kortet när flera finns. `Resolve-AdapterMapping` avvisar däremot alla exporter
som inte innehåller exakt ett källkort och returnerar null.

**Konsekvens:** även det primära nätverkskortet lämnas okonfigurerat i detta
körfall, trots att operatören har fått motsatt besked.

**Åtgärd:** stöd explicit mappning mellan källkort och målkort, eller blockera
det automatiska flödet redan före migreringen och dokumentera att samtliga
kort måste hanteras manuellt. Välj inte godtyckligt första kortet.

## 6. [P2] Automatisk state-sökning hittar bara första exporten från dagens datum

**Kod:** `Restore-And-TestMigrationState.ps1:90–98` och
`Migrate-VmwareToProxmox.ps1:217–242,305–307`.

Återställningen använder enbart dagens osuffixerade exportkatalog.
Exporten skapar däremot nya suffixerade kataloger vid omkörning.
Huvudskriptets `Get-LatestStatePath` används aldrig och huvudskriptet saknar
parameter för explicit state-katalog.

**Konsekvens:** migrering över midnatt hittar inga indata. Efter en ny export
samma dag kan återställningen använda gamla nätverksinställningar.

**Åtgärd:** förmedla en explicit state-katalog eller ett migrerings-ID genom
hela flödet. Kontrollera identitet och att exporten är komplett före användning.

## 7. [P2] Ett inaktiverat VirtIO-kort kan inte nå koden som aktiverar det

**Kod:** `Restore-And-TestMigrationState.ps1:268–278,352`.

Adaptermappningen kräver exakt ett VirtIO-kort med status `Up`. Först efter
godkänd mappning körs `Enable-NetAdapter`.

**Konsekvens:** ett unikt men inaktiverat målkort gör att nätverksåterställningen
hoppas över i stället för att kortet aktiveras som dokumentationen beskriver.

**Åtgärd:** skilj entydig hårdvaruidentifiering från länkstatus. Tillåt ett
entydigt inaktiverat kort, aktivera det under ShouldProcess och kontrollera
sedan länkstatus med en begränsad väntetid.

## 8. [P2] Aggressiv cleanup kan rapportera lyckad avinstallation utan att programmet avinstallerats

**Kod:** `Restore-And-TestMigrationState.ps1:929–1017`.

När MSI-avinstallation misslyckas raderas tjänster och avinstallationsnycklar.
Den avslutande PASS-bedömningen bygger på att avinstallationsnyckeln saknas,
vilket cleanup-koden själv precis har åstadkommit. Installerade filer/drivrutiner
och MSI-produktregistrering behöver inte ha tagits bort.

**Konsekvens:** ett delvis installerat och svårareparerat Tools kan rapporteras
som fullständigt avinstallerat. Ett tillfälligt MSI-fel eskaleras till manuell
radering i stället för att bevara ett tillstånd som kan repareras.

**Åtgärd:** rapportera MSI-fel och behåll produktregistreringen. Lägg eventuell
manuell sanering i ett separat, uttryckligt reparationsflöde med egen verifiering.

## 9. [P2] Inventering via Win32_Product kan påverka andra installerade program

**Kod:** `Restore-And-TestMigrationState.ps1:989`.

`Get-WmiObject Win32_Product` inventerar alla MSI-produkter innan PowerShell
filtrerar på VMware. Microsoft dokumenterar att detta startar konsistenskontroller
som kan verifiera och reparera installationer.

**Konsekvens:** ett kontrollsteg direkt efter migrering kan trigga reparationer
av andra applikationer och ge långa eller oväntade sidoeffekter.

**Åtgärd:** läs avinstallationsregistret eller fråga installer-API:t om en känd
produktkod utan att enumerera Win32_Product.

Källa: [Microsoft: Windows Installer reconfigured all applications](https://learn.microsoft.com/en-us/troubleshoot/windows-server/admin-development/windows-installer-reconfigured-all-applications).

## 10. [P2] Orkestreringen tillåter osignerad installer som standard

**Kod:** `Migrate-VmwareToProxmox.ps1:256` och
`mig_prep.ps1:142–154`.

Huvudflödet skickar alltid `-AllowUnsignedInstaller` utan förväntad SHA-256.
En helt osignerad EXE accepteras därmed och körs som administratör. Den beräknade
hashen loggas, men jämförs inte med något betrott värde i standardflödet.

**Åtgärd:** kräv giltig betrodd signatur eller en förankrad förväntad hash.
Låt ett eventuellt undantag vara ett uttryckligt operatörsval. Detta är en
brist i verifieringen, inte ett konstaterande att den medföljande EXE-filen är skadlig.

## Mindre fynd

- `mig_prep.ps1:12–13`: offlinefiler söks relativt aktuell arbetskatalog, inte
  `$PSScriptRoot`. Att starta huvudskriptet via absolut sökväg från annan katalog
  kan därför misslyckas trots att filerna ligger bredvid skriptet.
- `mig_prep.ps1:41–43`: parametrarna WorkingDirectory, StatusPath och LogPath
  skrivs över ovillkorligt och får ingen effekt.
- `Restore-And-TestMigrationState.ps1:365`: en befintlig IP-adress med fel
  prefixlängd korrigeras inte, eftersom endast adressen jämförs.
- `Restore-And-TestMigrationState.ps1:391–394`: en statisk route med annan
  next hop än default gateway antas tillhöra ett sekundärt kort. En sådan
  route kan mycket väl tillhöra samma kort; använd källans interfaceIndex.
- `Test-MigrationReadiness.ps1:331`: noll stoppade automatiska tjänster blir
  NOT_CHECKED trots att frågan lyckats och resultatet kan betyda att alla kör.
- `Migrate-VmwareToProxmox.ps1:146–159`: Test-IsLocalAdmin kontrollerar
  administratörsrollen, inte om kontot är lokalt. Ett domänkonto kan passera.
- `Export-MigrationState.ps1:195–208`: fel vid stopp/inaktivering ignoreras med
  SilentlyContinue och resultatet rapporteras ändå som PASS.
- README och kommentarsblock behöver uppdateras efter rättningarna, särskilt
  beträffande flera kort, automatisk nätverksåtkomst och efterkontroller.

## Rekommenderad verifiering efter rättning

1. Kör PowerShell 5.1-parser och PSScriptAnalyzer på en Windows-testmiljö.
2. Verifiera att WhatIf aldrig anropar installation, avinstallation eller
   native-kommandon som ändrar tillstånd.
3. Injicera drivrutins-, export- och valideringsfel och verifiera stopp samt
   korrekta returkoder hela vägen ut ur huvudskriptet.
4. Prova ett respektive flera kort, inaktiverat målkort, DHCP och statisk IP,
   separat statisk next hop samt nätverksrollback efter ett avsiktligt fel.
5. Prova ny export samma dag, export från föregående dag och körning från annan
   arbetskatalog. Verifiera att rätt state väljs.
6. Genomför en komplett återställning av en isolerad test-VM och kontrollera
   start från avsedd VirtIO-kontroller, nätverk, diskar, applikationer och omstart.
   Verifiera även att ValidatePost blockeras under pågående eller misslyckad
   Firstboot och först får fortsätta efter bekräftat avslut. För en DC behöver
   AD-, DNS-, SYSVOL- och replikeringskontroller ingå i godkännandet av migreringen.
   Eventuell separat egen sanering ska ske efter dessa kontroller; Firstboot kan
   redan ha tagit bort Tools före dem.

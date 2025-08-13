# X4 8.0 Named Pipes System - Bugfix Documentation

**Problem gelöst am: 2025-08-13**  
**X4 Version: 8.0**  
**Betroffene Komponenten: Named Pipes Inter-Process Communication**

---

## Problem Zusammenfassung

Das X4: Foundations Named Pipes System funktionierte nach dem Upgrade auf X4 8.0 nicht mehr korrekt:

- ✅ **Interface Commands** (ping, test_from_interface_init) erreichten den Python Server
- ❌ **MD-Script Commands** erreichten den Python Server nicht
- ❌ **Pipe-Verbindungen** schlugen fehl (No write/read file handle errors)

## Root Cause Analysis

**Hauptproblem: Doppelte Suffix-Anwendung**

1. **Named_Pipes.xml** fügte `_in`/`_out` Suffixe zu Pipe-Namen hinzu
2. **Pipes.lua** fügte **zusätzlich** `_in`/`_out` Suffixe hinzu  
3. **Resultat**: Falsche Pipe-Namen wie `x4_pipe_in_in` und `x4_pipe_out_out`

**Sekundärprobleme:**

- MD Debug-Logging war deaktiviert (`$DebugChance = 0`)
- Pipe-Verbindungsreihenfolge war suboptimal
- Interface Commands funktionierten nur, weil sie vor Connect-Versuchen gesendet wurden

## Debugging-Prozess

### 1. Symptom-Identifikation
```
X4 Log: [Pipes] Poll_For_Writes: No write file handle for pipe: x4_pipe_out
X4 Log: [Pipes] Poll_For_Reads: No read file handle for pipe: x4_pipe_in
Python Server: Nur Interface Commands empfangen, keine MD Commands
```

### 2. Interface vs. MD Command Analyse
```
Interface Commands: x4_pipe -> funktioniert
MD Commands: x4_pipe_out/x4_pipe_in -> funktioniert nicht
```

### 3. Suffix-Logik Analyse
```
MD: signal_cue_instantly cue="md.Named_Pipes.Write" param="table[$pipe='x4_pipe', ...]"
Named_Pipes.xml: x4_pipe + "_in" = "x4_pipe_in"  
Pipes.lua: "x4_pipe_in" + "_in" = "x4_pipe_in_in" (FEHLER!)
```

## Lösungsschritte

### 1. Entfernung der doppelten Suffix-Logik
**Datei:** `extensions\sn_mod_support_apis\md\Named_Pipes.xml`

**Vorher (Lines 651-672):**
```xml
<!-- Determine pipe suffix based on $is_server and $command -->
<do_if value="$is_server">
  <!-- Server logic: reverse suffixes -->
  <do_if value="$command == 'Write'">
    <set_value name="$pipe_suffix" exact="'_out'" />
  </do_if>
  <do_elseif value="$command == 'Read'">
    <set_value name="$pipe_suffix" exact="'_in'" />
  </do_elseif>
</do_if>
<do_else>
  <!-- Mod logic: original suffixes -->
  <do_if value="$command == 'Write'">
    <set_value name="$pipe_suffix" exact="'_in'" />
  </do_if>
  <do_elseif value="$command == 'Read'">
    <set_value name="$pipe_suffix" exact="'_out'" />
  </do_elseif>
</do_else>

<!-- Construct full pipe name -->
<set_value name="$full_pipe_name" exact="$pipe_name + $pipe_suffix" />
```

**Nachher:**
```xml
<!-- Use base pipe name directly - let Pipes.lua handle suffix logic -->
<set_value name="$full_pipe_name" exact="$pipe_name" />
```

### 2. Aktivierung des MD Debug-Loggings
**Datei:** `extensions\sn_mod_support_apis\md\Named_Pipes.xml`

**Geändert (Line 149):**
```xml
<!-- Debug printout chance; generally 0 or 100; ego style naming. -->
<set_value name="Globals.$DebugChance" exact="100" />  <!-- war: exact="0" -->
```

### 3. Verbesserung der Pipe-Verbindungsreihenfolge
**Datei:** `extensions\sn_mod_support_apis\ui\named_pipes\Pipes.lua`

**Geändert (Lines 132-134):**
```lua
-- Connect in same order as server expects: out first, then in
p.read_file = winpipe.open_pipe(rpath, "r")
p.write_file = winpipe.open_pipe(wpath, "w")
```

**Zusätzlich: Detailliertes Debug-Logging hinzugefügt:**
```lua
if isDebug then DebugError("[Pipes] Connect_Pipe: Trying to open read pipe: " .. rpath) end
p.read_file = winpipe.open_pipe(rpath, "r")
if isDebug then DebugError("[Pipes] Connect_Pipe: Read pipe result: " .. tostring(p.read_file)) end

if isDebug then DebugError("[Pipes] Connect_Pipe: Trying to open write pipe: " .. wpath) end  
p.write_file = winpipe.open_pipe(wpath, "w")
if isDebug then DebugError("[Pipes] Connect_Pipe: Write pipe result: " .. tostring(p.write_file)) end
```

## Verifikation des Fixes

### Python Server Logs (Erfolg):
```
2025-08-13 17:15:22,143 | DEBUG | Read from pipe: timestamp_test:1265.64
2025-08-13 17:15:22,143 | DEBUG | Read from pipe: simple_test:hello_from_x4
2025-08-13 17:15:22,143 | DEBUG | Read from pipe: write:[test1]5
2025-08-13 17:15:22,144 | DEBUG | Read from pipe: write:[test2]6
2025-08-13 17:15:22,144 | DEBUG | Read from pipe: write:[test3]7
2025-08-13 17:15:22,144 | DEBUG | Read from pipe: write:[test4]8
2025-08-13 17:15:22,144 | DEBUG | Read from pipe: read:[test1]
2025-08-13 17:15:22,144 | DEBUG | Read from pipe: read:[test2]  
2025-08-13 17:15:22,144 | DEBUG | Read from pipe: read:[test3]
2025-08-13 17:15:22,144 | DEBUG | Read from pipe: read:[test4]
```

### Funktionstest:
- ✅ Interface Commands (ping, test_from_interface_init)
- ✅ MD Write Commands (timestamp_test, simple_test, write:[test1-4])  
- ✅ MD Read Commands (read:[test1-4])
- ✅ Kontinuierliche Wiederholung (Script läuft zyklisch)
- ✅ Pipe-Verbindung stabil

## Wichtige Erkenntnisse

### Pipe-Namen-Architektur:
1. **MD Scripts**: Verwenden base name (`x4_pipe`)
2. **Named_Pipes.xml**: Leitet base name weiter (keine Suffixe)
3. **Pipes.lua**: Fügt automatisch `_in`/`_out` Suffixe hinzu
4. **Python Server**: Erstellt `x4_pipe_in` und `x4_pipe_out` Pipes

### Debug-Strategien für die Zukunft:
1. **MD Debug**: `Globals.$DebugChance` auf 100 setzen
2. **Lua Debug**: `isDebug = true` in Pipe-Modulen
3. **Server Debug**: `--verbose` Flag verwenden
4. **Log-Analyse**: X4 Log und Python Server Logs parallel prüfen

### Server-Versionen:
- **Script-Version**: `python -m X4_Python_Pipe_Server.Main` (verwendet `x4_pipe`)
- **Executable-Version**: `X4_Python_Pipe_Server.exe` (verwendet `x4_python_host`)
- ⚠️ **Wichtig**: Konsistente Pipe-Namen zwischen X4 und Server verwenden!

## Betroffene Dateien

```
E:\Projekte\x4-projects\extensions\sn_mod_support_apis\md\Named_Pipes.xml
- Entfernt: Doppelte Suffix-Logik (Lines 651-672)
- Aktiviert: Debug-Logging ($DebugChance = 100)

E:\Projekte\x4-projects\extensions\sn_mod_support_apis\ui\named_pipes\Pipes.lua  
- Verbessert: Pipe-Verbindungsreihenfolge
- Hinzugefügt: Detailliertes Debug-Logging für Connect-Prozess

E:\Projekte\x4-projects\extensions\test_named_pipes_api\ui\direct_pipe_test.lua
- Erstellt: Direkter Lua-Test zum Umgehen des MD-Systems (Debug-Zwecke)

E:\Projekte\x4-projects\extensions\test_named_pipes_api\md\Test_Named_Pipe.xml
- Verbessert: Test-Nachrichten mit Zeitstempel für besseres Debugging
```

## Testing Commands

### Python Server starten:
```bash
cd "E:\Projekte\x4-projects"
python -m X4_Python_Pipe_Server.Main --verbose
```

### X4 Log überwachen:
```bash  
tail -f "C:\Users\andre\Documents\Egosoft\X4\58011333\debug.log"
```

### Debug-Nachrichten suchen:
```bash
grep -i "Pipes.Interface\|Sending.*to.*x4_pipe\|Connected pipe" debug.log
```

## Kompatibilität

- ✅ **X4 8.0**: Vollständig funktionsfähig
- ✅ **Python 3.x**: Kompatibel
- ✅ **Windows Named Pipes**: Funktioniert
- ✅ **winpipe_64.dll**: Lädt korrekt

## Fazit

Das X4: Foundations Named Pipes System ist nach diesem Fix vollständig kompatibel mit X4 8.0. Der Hauptfehler war eine doppelte Anwendung von Pipe-Suffixen, die zu inkorrekten Pipe-Namen führte. Durch die Zentralisierung der Suffix-Logik in Pipes.lua und die Verbesserung des Debug-Loggings ist das System nun robust und wartbar.
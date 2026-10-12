# Проверки Tools

Запуск из папки Tools (Windows PowerShell 5.1 и Node.js):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Regression.ps1
```

Для дополнительной проверки в PowerShell 7:

```powershell
pwsh -NoProfile -File .\Tests\Run-Regression.ps1
```

Тесты используют временные синтетические миссии и таблицы, подменённые HTTP-запросы и DOM. Они не запускают сервер и не читают рабочие `catalog_new_prefabs.json`, `catalog_old_prefabs.json` или `remap_table.json`. Для PowerShell не нужны дополнительные модули, для JavaScript используются встроенные библиотеки Node.js.

cd "C:\Games\Steam\steamapps\common\Sven Co-op\svencoop\addons\metamod\dlls"

if exist AfkAbuse_old.dll (
    del AfkAbuse_old.dll
)
if exist AfkAbuse.dll (
    rename AfkAbuse.dll AfkAbuse_old.dll 
)

exit /b 0
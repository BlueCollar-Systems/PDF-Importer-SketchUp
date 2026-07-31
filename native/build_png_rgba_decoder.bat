@echo off
setlocal
set "ROOT=%~dp0.."
set "OUTPUT_DIR=%ROOT%\extracted\sketchup_ext\bc_pdf_vector_importer\native"
set "OUTPUT=%OUTPUT_DIR%\png_rgba_decoder.exe"
if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"
cl /nologo /O2 /MT /W4 /DUNICODE /D_UNICODE "%~dp0png_rgba_decoder.c" /Fe:"%OUTPUT%" /link bcrypt.lib
exit /b %ERRORLEVEL%

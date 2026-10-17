#!/usr/bin/env python3
"""Verify a read-only installer and the exact packaged app without opening Finder."""
import pathlib,subprocess,tempfile,os
import sys
with tempfile.TemporaryDirectory(prefix='allowance-dmg-check-') as folder:
    mount=pathlib.Path(folder,'mount'); mount.mkdir()
    archive=pathlib.Path(sys.argv[1]).resolve()
    subprocess.run(['hdiutil','attach','-readonly','-nobrowse','-mountpoint',str(mount),str(archive)],check=True,stdout=subprocess.DEVNULL)
    try:
        allowed={'Ai-llowance.app','Applications','Read me.txt','.DS_Store','.background','.background.png','.VolumeIcon.icns','.fseventsd','.Trashes'}
        if {p.name for p in mount.iterdir()}-allowed: raise SystemExit('Unexpected installer files: '+str(sorted({p.name for p in mount.iterdir()}-allowed)))
        if os.readlink(mount/'Applications')!='/Applications': raise SystemExit('Incorrect Applications shortcut')
        if not (mount/'.DS_Store').is_file() or not (mount/'Read me.txt').is_file(): raise SystemExit('Installer layout or instructions missing')
        subprocess.run(['codesign','--verify','--deep','--strict',str(mount/'Ai-llowance.app')],check=True)
        if os.environ.get('USAGEBAR_NOTARY_PROFILE') or os.environ.get('USAGEBAR_REQUIRE_NOTARIZATION')=='1':
            subprocess.run(['xcrun','stapler','validate',str(archive)],check=True)
            subprocess.run(['xcrun','stapler','validate',str(mount/'Ai-llowance.app')],check=True)
            subprocess.run(['spctl','--assess','--type','execute','--verbose=2',str(mount/'Ai-llowance.app')],check=True)
            subprocess.run(['spctl','--assess','--type','open','--context','context:primary-signature','--verbose=2',str(archive)],check=True)
        zipped=pathlib.Path(folder,'app.zip')
        subprocess.run(['ditto','-c','-k','--norsrc','--keepParent',str(mount/'Ai-llowance.app'),str(zipped)],check=True)
        subprocess.run([sys.executable,str(pathlib.Path(__file__).with_name('check-release.py')),str(zipped)],check=True)
    finally:
        subprocess.run(['hdiutil','detach',str(mount)],check=True,stdout=subprocess.DEVNULL)
print('DMG verified: drag-to-Applications layout, clean app contents and signature.')

#!/bin/sh
set -eu -o pipefail

centosversion='6.2'
centosiso="CentOS-${centosversion}-x86_64-minimal.iso"
centosmirror="http://rpm.iwg.local/centos/${centosversion}/isos/x86_64"
centosisourl="${centosmirror}/${centosiso}"

buildts=$(/bin/date '+%s.%N')
srcdir=$(/bin/pwd -P)
rootdir=$(/bin/mktemp -d)
trap '/bin/rm -rf "${rootdir}"' EXIT

echo "Downloading ${centosisourl} ..."
/usr/bin/curl -s -S -z "${srcdir}/${centosiso}" -O "${centosisourl}"

echo "Unpacking ${centosiso} ..."
/bin/mkdir "${rootdir}/iso"
/usr/bin/xorriso -osirrox on -indev "${srcdir}/${centosiso}" -extract / "${rootdir}/iso" > /dev/null 2>&1

echo 'Compiling VSP packages ...'
/bin/cat - > "${rootdir}/excludes" <<_EXCLUDES_
./aws/*
./graveyard/*
./netlinkz/vsp-policy-aws-*.rpm
./netlinkz/vsp-policy-azure-*.rpm
./repodata/*
./tools/*
_EXCLUDES_
cd "${srcdir}/repo/"
/bin/find . -type f -print \
	| /bin/tar -c -X "${rootdir}/excludes" -f - -T - \
	| (
		/bin/mkdir "${rootdir}/repo"
		cd "${rootdir}/repo"
		/bin/tar -x -f -
	)
cd - > /dev/null

echo 'Compiling CentOS packages ...'
/bin/mkdir -p "${rootdir}/iso/Packages/"
/bin/ln -s "${rootdir}/iso/Packages/" "${rootdir}/repo/"

echo 'Updating packages ...'
/usr/bin/repomanage -o "${rootdir}/repo/" | /usr/bin/xargs -t -n1 /bin/rm
/usr/bin/repomanage -n "${rootdir}/repo/" | (
	while read s; do
		t=$(/bin/basename "${s}")
		[ -f "${rootdir}/iso/Packages/${t}" ] \
			|| /bin/cp -p "${s}" "${rootdir}/iso/Packages/"
	done
)
# Explicitly remove any and all rsyslog RPM Packages which are not the rsyslog7
# RPM packages.
/bin/find "${rootdir}/iso/Packages/" -type f -name 'rsyslog-*.rpm' -delete

echo 'Generating comps.xml ...'
(
/bin/cat - <<_HEADER_
<?xml version='1.0' encoding='UTF-8'?>
<!DOCTYPE comps PUBLIC "-//CentOS//DTD Comps info//EN" "comps.dtd">
<comps>
  <group>
    <id>core</id>
    <name>Core</name>
    <description/>
    <default>true</default>
    <uservisible>false</uservisible>
    <packagelist>
_HEADER_
	/bin/find "${rootdir}/iso/Packages/" -type f -name '*.rpm' -print0 \
		| /usr/bin/xargs -0 -n1 /bin/rpm -qp --qf '<packagereq type="mandatory">%{NAME}</packagereq>\n'
/bin/cat - <<_FOOTER_
    </packagelist>
  </group>
  <category>
    <id>core</id>
    <name>Core</name>
    <description>Minimal package set</description>
    <grouplist>
      <groupid>core</groupid>
    </grouplist>
  </category>
</comps>
_FOOTER_
) | /usr/bin/xsltproc --path /usr/share/doc/comps-extras-17.8 comps-cleanup.xsl - > "${rootdir}/comps.xml"

echo 'Rebuilding repodata ...'
# Refer to http://release-engineering.github.io/productmd/discinfo-1.0.html
/bin/cat - > "${rootdir}/iso/.discinfo" <<_DISKINFO_
${buildts}
Link Platform
x86_64
ALL
_DISKINFO_
cd "${rootdir}/iso/"
# Remove everything from the repodata, including any CentOS 6.2 cruft, before
# creating the repodata.
/bin/find './repodata/' -type f -delete
/usr/bin/createrepo -u "media://${buildts}" -g "${rootdir}/comps.xml" .
cd - > /dev/null

echo 'Add Kickstart files ...'
/bin/cp -R "${srcdir}/kickstart" "${rootdir}/"

echo 'Building ISO ...'
version=$(
	/bin/find "${rootdir}/iso/Packages/" -type f -name 'vsp-launchpad*.rpm' -print0 \
		| /usr/bin/xargs -0 -n1 /bin/rpm -qp --qf '%{EVR}\n' \
		| /usr/bin/head -n1
)
# Refer to http://release-engineering.github.io/productmd/treeinfo-1.0.html
/bin/cat - > "${rootdir}/iso/.treeinfo" <<_TREEINFO_
[general]
family = Link Platform
version = ${version}
timestamp = ${buildts}
arch = x86_64
totaldiscs = 1
discnum = 1
variant =
packagedir = Packages

[images-x86_64]
initrd = images/pxeboot/initrd.img

[stage2]
mainimage = images/install.img
_TREEINFO_
vspiso="vsp-launchpad-${version}.iso"
volume="VSP_LaunchPad_${version}"
# Ensure write permissions to update files with mkisofs.
/bin/chmod -R u+w "${rootdir}/iso"
# Avoid having the same Joliet name with mkisofs.
/bin/rm -f "${rootdir}/iso/isolinux/isolinux.cfg"
# Remove any previous built ISO otherwise mkisofs will lay over the top of it.
/bin/rm -f "${srcdir}/${vspiso}"
/usr/bin/mkisofs \
	-quiet \
	-V "${volume}" \
	-p 'NetLinkz Limited' \
	-A "${volume}" \
	-o "${srcdir}/${vspiso}" \
	-b isolinux/isolinux.bin \
	-c islinux.cat \
	-no-emul-boot \
	-boot-load-size 4 \
	-boot-info-table \
	-R \
	-J \
	-T \
	-uid 0 \
	-gid 0 \
	-graft-points \
		"/=${rootdir}/iso" \
		"/ks=${rootdir}/kickstart" \
		"/isolinux=${srcdir}/isolinux"

echo 'Inserting MD5 into ISO ...'
/usr/bin/implantisomd5 "${srcdir}/${vspiso}"
/usr/bin/isovfy "${srcdir}/${vspiso}"

echo "Created ${vspiso}"

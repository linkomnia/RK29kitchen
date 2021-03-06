#!/bin/bash
#set -vx

TZ=UTC
export TZ
tempfile=`mktemp 2>/dev/null` || tempfile=/tmp/rk29$$
tempdir=`mktemp -d 2>/dev/null` || tempdir=/tmp/rk29d$$
mkdir -p $tempdir 2>/dev/null

export tempfile tempdir

trap "rm -rf $tempfile $tempdir" 0 1 2 5 15


#1 - menu title; 2-function
declare MENUITEM
declare FUNCTION
N=0
MenuAdd(){
	N=$[N+1]
	MENUITEMS="${MENUITEMS} \"$N\" \"$1\""
	FUNCTION[$N]="$2"
}

dialogBT(){
	DIALOGBT="Work dir: \Z1${WORKDIR}\Zn Mode:\Z2${WORKMODE}\Zn Parameter file:\Z3${PARAMFILE}\Zn" 
}

dialogINF(){
	dialogBT
	dialog --colors --backtitle "${DIALOGBT}" --infobox "$1" 8 70
}

dialogOK(){
	dialogBT
	dialog --colors --backtitle "${DIALOGBT}" --msgbox "$1" 8 70
}

dialogYN(){
	dialogBT
	dialog --colors --backtitle "${DIALOGBT}" --yesno "$1" 8 70
}

dialogLOG(){
	dialogBT
	dialog --colors --backtitle "${DIALOGBT}" --msgbox "$1" 8 70
	dialog --colors --backtitle "${DIALOGBT}" --title "Show log" --textbox ""${LOGFILE}"" 20 70
}

pressEnterToContinue(){
	echo -n "Press Enter to continue..."
	read a
}

BackupFile(){
	fn="$1"
	s="#"

	if [ ! -f "$fn" ]
	then
		echo File $fn not found
		return
	fi

	old="${fn}"
	while [ true ]
	do
		old="${old}${s}"
		if [ -f "${old}" ]
		then
			continue
		fi
		cp "${fn}" "${old}"
		COMMONBACKUPFILE="${old}"
		break
	done
}

# first 4 bytes of file. 'ANDR' or 'KRNL' for android img files 
FileSignature(){
	fn=$1
	sigSize=${2:-4}
	COMMONFILESIGNATURE=`dd if="$1" bs=1 count=4`
}

SystemFsck(){
	pushd "$WORKDIR/Image"  2>/dev/null
	sudo sync
	sudo /sbin/fsck.ext3 -yf system.img 2>&1 >> "$LOGFILE"
	popd
}

SystemMount(){
	pushd "$WORKDIR/Image"  2>/dev/null
	if [ ! -d "system" ]
	then
		mkdir "system"
	fi
	if [ ! -f "system/build.prop" ]
	then
		SystemFsck
		sudo mount system.img system -o loop 2>>"${LOGFILE}"
	fi
	popd  2>/dev/null
}

SystemUmount(){
	pushd "$WORKDIR/Image"  2>/dev/null
	if [ -d "system" ] && [ -f "system/build.prop" ]
	then
		sudo sync
		sudo umount system  2>>"${LOGFILE}"
		SystemFsck
	fi
	popd  2>/dev/null
}

SetDirPermissions(){
	path=$1
	uid=$2
	gid=$3
	fmod=$4
	dmod=$5
	find ${path} -type f -print0| xargs -0 sudo chmod ${fmod} 2>>${LOGFILE}
	find ${path} -type d -print0| xargs -0 sudo chmod ${dmod} 2>>${LOGFILE}
	sudo chown -R ${uid}:${gid} "${path}" 2>>${LOGFILE}
}

SetFilePermissions(){
	fn="$1"
	uid="$2"
	gid="$3"
	mod="$4"
	sudo chmod ${mod} "$fn" 2>>"${LOGFILE}"
	sudo chown ${uid}:${gid} "$fn" 2>>"${LOGFILE}"
}

SystemFixPermissions(){
	SystemMount
	pushd "$WORKDIR/Image"  2>/dev/null
	SetDirPermissions system/app/ 0 0 0644 0755
	SetDirPermissions system/lib/ 0 0 0644 0755
	SetDirPermissions system/bin/ 0 0 0755 0755
	SetDirPermissions system/xbin/ 0 0 0755 0755
	sudo chmod +s system/xbin/su
	popd 2>/dev/null
}

ApkLibExtract(){
	apk="$1"
	APKLIBDIR=""
	APKLIBFILES=""
	if [ -z "$apk" ]
	then
		return
	fi
	APKLIBDIR="$tempdir/$apk/"
	unzip "$apk" -d "$APKLIBDIR" "*.so" 2>>"${LOGFILE}" >>"${LOGFILE}"
	pushd "$APKLIBDIR"
	if [ -d lib/armeabi-v7a ]
	then
		mv lib/armeabi-v7a/*.so . 2>>"${LOGFILE}"
	elif [ -d lib/armeabi ]
	then
		mv lib/armeabi/*.so . 2>>"${LOGFILE}"
	fi
	rm -rf lib 2>/dev/null
	APKLIBFILES=$(ls -1 *.so)
	popd 2>/dev/null
}

DirToArray(){
	fn="$1"
	ifs=$IFS
	IFS=$'\n'
	FILEARRAY=($(ls -1 ${fn} 2>>"${LOGFILE}"))
	IFS=$ifs
}

FileToArray(){
	fn="$1"
	ifs=$IFS
	IFS=$'\n'
	FILEARRAY=( `sort $fn|sed -e 's/" *"/\n/g'|sed -e 's/"//g'` )
	IFS=$ifs
}

# ListCheckboxDlg LISTON[@] FILEARRAY[@] "Install" "Choose files:"
ListCheckboxDlg(){
	listOn=("${!1}")
	listOff=("${!2}")
	titletxt="$3"
	headertxt="$4"
	lst=""
	if [ ! -z "${listOn[0]}" ]
	then
		listsize=${#listOn[@]}
		for (( i=0; i<${listsize}; i++ ))
		do
			f=${listOn[$i]}
			if [ -z "$f" ]
			then
				continue
			fi
			lst="${lst} \"${f}\" \"\" on"
		done
	fi
	if [ ! -z "${listOff[0]}" ]
	then

		listsize=${#listOff[@]}
		for (( i=0; i<${listsize}; i++ ))
		do
			f=${listOff[$i]}
			if [ -z "$f" ]
			then
				continue
			fi
			lst="${lst} \"${f}\" \"\" off"
		done
	fi
	if [ ! -z "${lst}" ]
	then

		dialogBT
		echo $lst|xargs dialog --colors --backtitle "${DIALOGBT}" --separate-output --title "$titletxt" --checklist "$headertxt" 20 70 15 2>$tempfile
		r=$?
		FileToArray "$tempfile"
	else
		dialogOK "Empty list"
		r=1
	fi
	return $r
}

# FilesMenuDlg "*.img" "Extract img file" "Choose file:" 
FilesMenuDlg(){
	fn="$1"
	titletxt="$2"
	headertxt="$3"
	DirToArray "${fn}"
	n=${#FILEARRAY[@]}
	lst=""
	for (( i=0; i<${n}; i++ ))
	do
		f=${FILEARRAY[$i]}
		if [ -z "$f" ]
		then
			continue
		fi
		lst="${lst} \"${f}\" \"\""
	done

	dialogBT
	echo $lst | xargs dialog --colors --backtitle "${DIALOGBT}" --title "$titletxt" --menu "$headertxt" 20 70 15 2>$tempfile
	r=$?
	return $r
}

# FileMenuMenuDlg "path/menufile" "Change default" "Select:" 
FileMenuMenuDlg(){
	fn="$1"
	titletxt="$2"
	headertxt="$3"
	dialogBT
	cat "$fn"| xargs dialog --colors --backtitle "${DIALOGBT}" --title "$titletxt" --menu "$headertxt" 20 70 15 2>$tempfile
	r=$?
	return $r
}

# MenuDlgFromFile "path/menufile" "Change default" "Select:" 
ListMenuDlg(){
	fn="$1"
	titletxt="$2"
	headertxt="$3"
	FileToArray "${fn}"
	n=${#FILEARRAY[@]}
	lst=""
	for (( i=0; i<${n}; i++ ))
	do
		e=${FILEARRAY[$i]}
		if [ -z "$e" ]
		then
			continue
		fi
		lst="${lst} \"${e}\" \"\""
	done

	dialogBT
	echo $lst | xargs dialog --colors --backtitle "${DIALOGBT}" --title "$titletxt" --menu "$headertxt" 20 70 15 2>$tempfile
	r=$?
	return $r
}


GetBuildProp(){
	prop="$1"
	file="$WORKDIR/Image/system/build.prop"
	BUILDPROP=$(grep "${prop}=" "$file"|cut -d= -f2)
}

SetBuildProp(){
	prop="$1"
	value="$2"
	file="$WORKDIR/Image/system/build.prop"
	if [ ! -f "${file}.original" ]
	then
		sudo cp "$file" "${file}.original"
	fi
	grep -q "${prop}=" "$file"
	if [ $? -eq 0 ]
	then
		cat "$file"| sed -e "s|^${prop}=.*$|${prop}=${value}|" > "$tempdir/build.prop"
		sudo mv "$tempdir/build.prop" "$file"
	else
		sudo echo "" >> "$file"
		sudo echo "${prop}=${value}" >> "$file"
	fi
}



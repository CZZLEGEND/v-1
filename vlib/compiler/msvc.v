module compiler

import os

#flag windows -l shell32
#flag windows -l dbghelp
// RegOpenKeyExW etc
#flag windows -l advapi32

struct MsvcResult {
	full_cl_exe_path string
	exe_path string

	um_lib_path string
	ucrt_lib_path string
	vs_lib_path string

	um_include_path string
	ucrt_include_path string
	vs_include_path string
	shared_include_path string
}

// Mimics a HKEY
type RegKey voidptr

// Taken from the windows SDK
const (
	HKEY_LOCAL_MACHINE = RegKey(0x80000002)
	KEY_QUERY_VALUE = (0x0001)
	KEY_WOW64_32KEY = (0x0200)
	KEY_ENUMERATE_SUB_KEYS = (0x0008)
)

// Given a root key look for one of the subkeys in 'versions' and get the path
fn find_windows_kit_internal(key RegKey, versions []string) ?string {
	$if windows {
		for version in versions {
			required_bytes := 0 // TODO mut
			result := C.RegQueryValueEx(key, version.to_wide(), 0, 0, 0, &required_bytes)

			length := required_bytes / 2

			if result != 0 {
				continue
			}

			alloc_length := (required_bytes + 2)

			mut value := &u16(malloc(alloc_length))
			if isnil(value) {
				continue
			}

			result2 := C.RegQueryValueEx(key, version.to_wide(), 0, 0, value, &alloc_length)

			if result2 != 0 {
				continue
			}

			// We might need to manually null terminate this thing
			// So just make sure that we do that
			if (value[length - 1] != u16(0)) {
				value[length] = u16(0)
			}

			return string_from_wide(value)
		}
	}
	return error('windows kit not found')
}

struct WindowsKit {
	um_lib_path string
	ucrt_lib_path string

	um_include_path string
	ucrt_include_path string
	shared_include_path string
}

// Try and find the root key for installed windows kits
fn find_windows_kit_root(host_arch string) ?WindowsKit {
	$if windows {
		root_key := RegKey(0)
		rc := C.RegOpenKeyEx(
			HKEY_LOCAL_MACHINE, 'SOFTWARE\\Microsoft\\Windows Kits\\Installed Roots'.to_wide(), 0, KEY_QUERY_VALUE | KEY_WOW64_32KEY | KEY_ENUMERATE_SUB_KEYS, &root_key)

		defer {C.RegCloseKey(root_key)}

		if rc != 0 {
			return error('Unable to open root key')
		}
		// Try and find win10 kit
		kit_root := find_windows_kit_internal(root_key, ['KitsRoot10', 'KitsRoot81']) or {
			return error('Unable to find a windows kit')
		}

		kit_lib := kit_root + 'Lib'

		// println(kit_lib)

		files := os.ls(kit_lib) or { panic(err) }
		mut highest_path := ''
		mut highest_int := 0
		for f in files {
			no_dot := f.replace('.', '')
			v_int := no_dot.int()

			if v_int > highest_int {
				highest_int = v_int
				highest_path = f
			}
		}

		kit_lib_highest := kit_lib + '\\$highest_path'
		kit_include_highest := kit_lib_highest.replace('Lib', 'Include')

		// println('$kit_lib_highest $kit_include_highest')

		return WindowsKit {
			um_lib_path: kit_lib_highest + '\\um\\$host_arch'
			ucrt_lib_path: kit_lib_highest + '\\ucrt\\$host_arch'

			um_include_path: kit_include_highest + '\\um'
			ucrt_include_path: kit_include_highest + '\\ucrt'
			shared_include_path: kit_include_highest + '\\shared'
		}
	}
	return error('Host OS does not support funding a windows kit')
}

struct VsInstallation {
	include_path string
	lib_path string
	exe_path string
}

fn find_vs(vswhere_dir string, host_arch string) ?VsInstallation {
	$if !windows {
		return error('Host OS does not support finding a Vs installation')
	}
	// Emily:
	// VSWhere is guaranteed to be installed at this location now
	// If its not there then end user needs to update their visual studio
	// installation!
	
	res := os.exec('"$vswhere_dir\\Microsoft Visual Studio\\Installer\\vswhere.exe" -latest -prerelease -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath') or {
		return error(err)
	}
	// println('res: "$res"')

	version := os.read_file('$res.output\\VC\\Auxiliary\\Build\\Microsoft.VCToolsVersion.default.txt') or {
		println('Unable to find msvc version')
		return error('Unable to find vs installation')
	}

	// println('version: $version')

	v := if version.ends_with('\n') {
		version[..version.len - 2]
	} else {
		version
	}

	lib_path := '$res.output\\VC\\Tools\\MSVC\\$v\\lib\\$host_arch'
	include_path := '$res.output\\VC\\Tools\\MSVC\\$v\\include'

	if os.exists('$lib_path\\vcruntime.lib') {
		p := '$res.output\\VC\\Tools\\MSVC\\$v\\bin\\Host$host_arch\\$host_arch'

		// println('$lib_path $include_path')

		return VsInstallation{
			exe_path: p
			lib_path: lib_path
			include_path: include_path
		}
	}

	println('Unable to find vs installation (attempted to use lib path "$lib_path")')
	return error('Unable to find vs exe folder')
}

fn find_msvc() ?MsvcResult {
	$if windows {
		processor_architecture := os.getenv('PROCESSOR_ARCHITECTURE')
		vswhere_dir := if processor_architecture == 'x86' {
			'%ProgramFiles%'
		} else {
			'%ProgramFiles(x86)%'
		}
		host_arch := if processor_architecture == 'x86' {
			'X86'
		} else {
			'X64'
		}
		wk := find_windows_kit_root(host_arch) or {
			return error('Unable to find windows sdk')
		}
		vs := find_vs(vswhere_dir, host_arch) or {
			return error('Unable to find visual studio')
		}

		return MsvcResult {
			full_cl_exe_path: os.realpath( vs.exe_path + os.path_separator + 'cl.exe' )
			exe_path: vs.exe_path,

			um_lib_path: wk.um_lib_path,
			ucrt_lib_path: wk.ucrt_lib_path,
			vs_lib_path: vs.lib_path,

			um_include_path: wk.um_include_path,
			ucrt_include_path: wk.ucrt_include_path,
			vs_include_path: vs.include_path,
			shared_include_path: wk.shared_include_path,
		}
	}
	$else {
		verror('Cannot find msvc on this OS')
		return error('msvc not found')
	}
}

pub fn (v mut V) cc_msvc() {
	r := find_msvc() or {
		// TODO: code reuse
		if !v.pref.is_keep_c && v.out_name_c != 'v.c' && v.out_name_c != 'v_macos.c' {
			os.rm(v.out_name_c)
		}
		verror('Cannot find MSVC on this OS')
		return
	}

	out_name_obj := os.realpath( v.out_name_c + '.obj' )

	// Default arguments

	// volatile:ms enables atomic volatile (gcc _Atomic)
	// -w: no warnings
	// 2 unicode defines
	// /Fo sets the object file name - needed so we can clean up after ourselves properly
	mut a := ['-w', '/we4013', '/volatile:ms', '/Fo"$out_name_obj"']

	if v.pref.is_prod {
		a << '/O2'
		a << '/MD'
		a << '/Zi'
		a << '/DNDEBUG'
	} else {
		a << '/Zi'
		a << '/MDd'
	}

	if v.pref.is_so {
		if !v.out_name.ends_with('.dll') {
			v.out_name = v.out_name + '.dll'
		}

		// Build dll
		a << '/LD'
	} else if !v.out_name.ends_with('.exe') {
		v.out_name = v.out_name + '.exe'
	}

	v.out_name = os.realpath( v.out_name )

	//alibs := []string // builtin.o os.o http.o etc
	if v.pref.build_mode == .build_module {
		// Compile only
		a << '/c'
	}
	else if v.pref.build_mode == .default_mode {
		/*
		b := os.realpath( '$v_modules_path/vlib/builtin.obj' )
		alibs << '"$b"'
		if !os.exists(b) {
			println('`builtin.obj` not found')
			exit(1)
		}
		for imp in v.table.imports {
			if imp == 'webview' {
				continue
			}
			alibs << '"' + os.realpath( '$v_modules_path/vlib/${imp}.obj' ) + '"'
		}
		*/
	}

	if v.pref.sanitize {
		println('Sanitize not supported on msvc.')
	}

	// The C file we are compiling
	//a << '"$TmpPath/$v.out_name_c"'
	a << '"' + os.realpath( v.out_name_c ) + '"'

	// Emily:
	// Not all of these are needed (but the compiler should discard them if they are not used)
	// these are the defaults used by msbuild and visual studio
	mut real_libs :=  [
		'kernel32.lib',
		'user32.lib',
		'gdi32.lib',
		'winspool.lib',
		'comdlg32.lib',
		'advapi32.lib',
		'shell32.lib',
		'ole32.lib',
		'oleaut32.lib',
		'uuid.lib',
		'odbc32.lib',
		'odbccp32.lib'
	]

	sflags := v.get_os_cflags().msvc_string_flags()
	real_libs   << sflags.real_libs
	inc_paths   := sflags.inc_paths
	lib_paths   := sflags.lib_paths
	other_flags := sflags.other_flags

	// Include the base paths
	a << '-I "$r.ucrt_include_path"'
	a << '-I "$r.vs_include_path"'
	a << '-I "$r.um_include_path"'
	a << '-I "$r.shared_include_path"'

	a << inc_paths

	a << other_flags

	// Libs are passed to cl.exe which passes them to the linker
	a << real_libs.join(' ')

	a << '/link'
	a << '/NOLOGO'
	a << '/OUT:"$v.out_name"'
	a << '/LIBPATH:"$r.ucrt_lib_path"'
	a << '/LIBPATH:"$r.um_lib_path"'
	a << '/LIBPATH:"$r.vs_lib_path"'
	a << '/DEBUG:FULL' // required for prod builds to generate PDB

	if v.pref.is_prod {
		a << '/INCREMENTAL:NO' // Disable incremental linking
		a << '/OPT:REF'
		a << '/OPT:ICF'
	}

	a << lib_paths
	
	args := a.join(' ')

	cmd := '"$r.full_cl_exe_path" $args'
	// It is hard to see it at first, but the quotes above ARE balanced :-| ...
	// Also the double quotes at the start ARE needed.
	if v.pref.show_c_cmd || v.pref.is_verbose {
		println('\n========== cl cmd line:')
		println(cmd)
		println('==========\n')
	}

	// println('$cmd')

	res := os.exec(cmd) or {
		println(err)
		verror('msvc error')
		return
	}
	if res.exit_code != 0 {
		verror(res.output)
	}
	// println(res)
	// println('C OUTPUT:')

	if !v.pref.is_keep_c && v.out_name_c != 'v.c' && v.out_name_c != 'v_macos.c' {
		os.rm(v.out_name_c)
	}

	// Always remove the object file - it is completely unnecessary
	os.rm(out_name_obj)
}
fn build_thirdparty_obj_file_with_msvc(path string, moduleflags []CFlag) {
	msvc := find_msvc() or {
		println('Could not find visual studio')
		return
	}

	// msvc expects .obj not .o
	mut obj_path := '${path}bj'

	obj_path = os.realpath(obj_path)

	if os.exists(obj_path) {
		println('$obj_path already build.')
		return
	}

	println('$obj_path not found, building it (with msvc)...')
	parent := os.dir(obj_path)
	files := os.ls(parent) or { panic(err) }

	mut cfiles := ''
	for file in files {
		if file.ends_with('.c') {
			cfiles += '"' + os.realpath( parent + os.path_separator + file )  + '" '
		}
	}

	include_string := '-I "$msvc.ucrt_include_path" -I "$msvc.vs_include_path" -I "$msvc.um_include_path" -I "$msvc.shared_include_path"'

	//println('cfiles: $cfiles')

	btarget := moduleflags.c_options_before_target_msvc()
	atarget := moduleflags.c_options_after_target_msvc()
	cmd := '"$msvc.full_cl_exe_path" /volatile:ms /Zi /DNDEBUG $include_string /c $btarget $cfiles $atarget /Fo"$obj_path"'
	//NB: the quotes above ARE balanced.
	println('thirdparty cmd line: $cmd')
	res := os.exec(cmd) or {
		println('msvc: failed thirdparty object build cmd: $cmd')
		verror(err)
		return
	}
	if res.exit_code != 0 {
		println('msvc: failed thirdparty object build cmd: $cmd')
		verror(res.output)
		return
	}
	println(res.output)
}


struct MsvcStringFlags {
mut:
	real_libs []string
	inc_paths []string
	lib_paths []string
	other_flags []string
}

fn (cflags []CFlag) msvc_string_flags() MsvcStringFlags {
	mut real_libs := []string
	mut inc_paths := []string
	mut lib_paths := []string
	mut other_flags := []string	
	for flag in cflags {
		//println('fl: $flag.name | flag arg: $flag.value')		
		// We need to see if the flag contains -l
		// -l isnt recognised and these libs will be passed straight to the linker
		// by the compiler
		if flag.name == '-l' {
			if flag.value.ends_with('.dll') {
				verror('MSVC cannot link against a dll (`#flag -l $flag.value`)')
			}
			// MSVC has no method of linking against a .dll
			// TODO: we should look for .defs aswell
			lib_lib := flag.value + '.lib'
			real_libs << lib_lib
		}
		else if flag.name == '-I' {
			inc_paths << flag.format()
		}
		else if flag.name == '-L' {
			lib_paths << flag.value
			lib_paths << flag.value + os.path_separator + 'msvc'
			// The above allows putting msvc specific .lib files in a subfolder msvc/ ,
			// where gcc will NOT find them, but cl will do...
			// NB: gcc is smart enough to not need .lib files at all in most cases, the .dll is enough.
			// When both a msvc .lib file and .dll file are present in the same folder,
			// as for example for glfw3, compilation with gcc would fail.
		}
		else if flag.value.ends_with('.o') {
			// msvc expects .obj not .o
			other_flags << '"${flag.value}bj"'
		}
		else {
			other_flags << flag.value
		}
	}

	mut lpaths := []string
	for l in lib_paths {
		lpaths << '/LIBPATH:"' + os.realpath(l) + '"'
	}

	return MsvcStringFlags{ real_libs, inc_paths, lpaths, other_flags }
}

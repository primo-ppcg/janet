### cook.janet
###
### Library to help build janet natives and other
### build artifacts.
###
### Copyright 2019 © Calvin Rose

#
# Basic Path Settings
#

# Windows is the OS outlier
(def- is-win (= (os/which) :windows))
(def- is-mac (= (os/which) :macos))
(def- sep (if is-win "\\" "/"))
(def- objext (if is-win ".obj" ".o"))
(def- modext (if is-win ".dll" ".so"))
(def- statext (if is-win ".static.lib" ".a"))
(def- absprefix (if is-win "C:\\" "/"))

#
# Rule Engine
#

(defn- getrules []
  (if-let [rules (dyn :rules)] rules (setdyn :rules @{})))

(defn- gettarget [target]
  (def item ((getrules) target))
  (unless item (error (string "No rule for target " target)))
  item)

(defn- rule-impl
  [target deps thunk &opt phony]
  (put (getrules) target @[(array/slice deps) thunk phony]))

(defmacro rule
  "Add a rule to the rule graph."
  [target deps & body]
  ~(,rule-impl ,target ,deps (fn [] nil ,;body)))

(defmacro phony
  "Add a phony rule to the rule graph. A phony rule will run every time
  (it is always considered out of date). Phony rules are good for defining
  user facing tasks."
  [target deps & body]
  ~(,rule-impl ,target ,deps (fn [] nil ,;body) true))

(defn add-dep
  "Add a dependency to an existing rule. Useful for extending phony
  rules or extending the dependency graph of existing rules."
  [target dep]
  (def [deps] (gettarget target))
  (array/push deps dep))

(defn- add-thunk
  [target more]
  (def item (gettarget target))
  (def [_ thunk] item)
  (put item 1 (fn [] (more) (thunk))))

(defmacro add-body
  "Add recipe code to an existing rule. This makes existing rules do more but
  does not modify the dependency graph."
  [target & body]
  ~(,add-thunk ,target (fn [] ,;body)))

(defn- needs-build
  [dest src]
  (let [mod-dest (os/stat dest :modified)
        mod-src (os/stat src :modified)]
    (< mod-dest mod-src)))

(defn- needs-build-some
  [dest sources]
  (def f (file/open dest))
  (if (not f) (break true))
  (file/close f)
  (some (partial needs-build dest) sources))

(defn do-rule
  "Evaluate a given rule."
  [target]
  (def item ((getrules) target))
  (unless item
    (if (os/stat target :mode)
      (break target)
      (error (string "No rule for file " target " found."))))
  (def [deps thunk phony] item)
  (def realdeps (seq [dep :in deps :let [x (do-rule dep)] :when x] x))
  (when (or phony (needs-build-some target realdeps))
    (thunk))
  (unless phony target))

#
# Configuration
#

(def JANET_MODPATH (or (os/getenv "JANET_MODPATH") (dyn :syspath)))
(def JANET_HEADERPATH (or (os/getenv "JANET_HEADERPATH")
                          (if-let [j JANET_MODPATH]
                            (string j "/../../include/janet"))))
(def JANET_BINPATH (or (os/getenv "JANET_BINPATH")
                       (if-let [j JANET_MODPATH]
                         (string j "/../../bin"))))
(def JANET_LIBPATH (or (os/getenv "JANET_LIBPATH")
                       (if-let [j JANET_MODPATH]
                         (string j "/.."))))

#
# Compilation Defaults
#

(def default-compiler (if is-win "cl" "cc"))
(def default-linker (if is-win "link" "cc"))
(def default-archiver (if is-win "lib" "ar"))

# Default flags for natives, but not required
(def default-lflags (if is-win ["/nologo"] []))
(def default-cflags
  (if is-win
    ["/nologo"]
    ["-std=c99" "-Wall" "-Wextra"]))

# Required flags for dynamic libraries. These
# are used no matter what for dynamic libraries.
(def- dynamic-cflags
  (if is-win
    []
    ["-fpic"]))
(def- dynamic-lflags
    (if is-win
      ["/DLL"]
      (if is-mac
        ["-shared" "-undefined" "dynamic_lookup"]
        ["-shared"])))

(defn- opt
  "Get an option, allowing overrides via dynamic bindings AND some
  default value dflt if no dynamic binding is set."
  [opts key dflt]
  (def ret (or (opts key) (dyn key dflt)))
  (if (= nil ret)
    (error (string "option :" key " not set")))
  ret)

#
# Importing a file
#

(def- _env (fiber/getenv (fiber/current)))

(defn- proto-flatten
  [into x]
  (when x
    (proto-flatten into (table/getproto x))
    (loop [k :keys x]
      (put into k (x k))))
  into)

(defn import-rules
  "Import another file that defines more cook rules. This ruleset
  is merged into the current ruleset."
  [path]
  (def env (make-env))
  (unless (os/stat path :mode)
    (error (string "cannot open " path)))
  (loop [k :keys _env :when (symbol? k)]
     (unless ((_env k) :private) (put env k (_env k))))
  (def currenv (proto-flatten @{} (fiber/getenv (fiber/current))))
  (loop [k :keys currenv :when (keyword? k)]
    (put env k (currenv k)))
  (dofile path :env env :exit true)
  (when-let [rules (env :rules)] (merge-into (getrules) rules)))

#
# OS and shell helpers
#

(def- filepath-replacer
  "Convert url with potential bad characters into a file path element."
  (peg/compile ~(% (any (+ (/ '(set "<>:\"/\\|?*") "_") '1)))))

(defn filepath-replace
  "Remove special characters from a string or path
  to make it into a path segment."
  [repo]
  (get (peg/match filepath-replacer repo) 0))

(defn shell
  "Do a shell command"
  [& args]
  (if (dyn :verbose)
    (print ;(interpose " " args)))
  (def res (os/execute args :p))
  (unless (zero? res)
    (error (string "command exited with status " res))))

(defn rm
  "Remove a directory and all sub directories."
  [path]
  (if (= (os/stat path :mode) :directory)
    (do
      (each subpath (os/dir path)
        (rm (string path sep subpath)))
      (os/rmdir path))
    (os/rm path)))

(defn copy
  "Copy a file or directory recursively from one location to another."
  [src dest]
  (print "copying " src " to " dest "...")
  (if is-win
    (shell "xcopy" src dest "/y" "/e")
    (shell "cp" "-rf" src dest)))

#
# C Compilation
#

(defn- embed-name
  "Rename a janet symbol for embedding."
  [path]
  (->> path
       (string/replace-all sep "___")
       (string/replace-all ".janet" "")))

(defn- out-path
  "Take a source file path and convert it to an output path."
  [path from-ext to-ext]
  (->> path
       (string/replace-all sep "___")
       (string/replace-all from-ext to-ext)
       (string "build" sep)))

(defn- make-define
  "Generate strings for adding custom defines to the compiler."
  [define value]
  (if value
    (string (if is-win "/D" "-D") define "=" value)
    (string (if is-win "/D" "-D") define)))

(defn- make-defines
  "Generate many defines. Takes a dictionary of defines. If a value is
  true, generates -DNAME (/DNAME on windows), otherwise -DNAME=value."
  [defines]
  (seq [[d v] :pairs defines] (make-define d (if (not= v true) v))))

(defn- getcflags
  "Generate the c flags from the input options."
  [opts]
  @[;(opt opts :cflags default-cflags)
    (string (if is-win "/I" "-I") (dyn :headerpath JANET_HEADERPATH))
    (string (if is-win "/O" "-O") (opt opts :optimize 2))])

(defn- entry-name
  "Name of symbol that enters static compilation of a module."
  [name]
  (string "janet_module_entry_" (filepath-replace name)))

(defn- compile-c
  "Compile a C file into an object file."
  [opts src dest &opt static?]
  (def cc (opt opts :compiler default-compiler))
  (def cflags [;(getcflags opts) ;(if static? [] dynamic-cflags)])
  (def entry-defines (if-let [n (opts :entry-name)]
                       [(make-define "JANET_ENTRY_NAME" n)]
                       []))
  (def defines [;(make-defines (opt opts :defines {})) ;entry-defines])
  (def headers (or (opts :headers) []))
  (rule dest [src ;headers]
        (print "compiling " dest "...")
        (if is-win
          (shell cc ;defines "/c" ;cflags (string "/Fo" dest) src)
          (shell cc "-c" src ;defines ;cflags "-o" dest))))

(defn- libjanet
  "Find libjanet.a (or libjanet.lib on windows) at compile time"
  []
  (def libpath (dyn :libpath JANET_LIBPATH))
  (unless libpath
    (error "cannot find libpath: provide --libpath or JANET_LIBPATH"))
  (string (dyn :libpath JANET_LIBPATH)
          sep
          (if is-win "libjanet.lib" "libjanet.a")))

(defn- win-import-library
  "On windows, an import library is needed to link to a dll statically."
  []
  (def hpath (dyn :headerpath JANET_HEADERPATH))
  (unless hpath
    (error "cannot find headerpath: provide --headerpath or JANET_HEADERPATH"))
  (string hpath `\\janet.lib`))

(defn- link-c
  "Link object files together to make a native module."
  [opts target & objects]
  (def ld (opt opts :linker default-linker))
  (def cflags (getcflags opts))
  (def lflags [;(opt opts :lflags default-lflags)
               ;(if (opts :static) [] dynamic-lflags)])
  (rule target objects
        (print "linking " target "...")
        (if is-win
          (shell ld ;lflags (string "/OUT:" target) ;objects (win-import-library))
          (shell ld ;cflags `-o` target ;objects ;lflags))))

(defn- archive-c
  "Link object files together to make a static library."
  [opts target & objects]
  (def ar (opt opts :archiver default-archiver))
  (rule target objects
        (print "creating static library " target "...")
        (if is-win
          (shell ar "/nologo" (string "/out:" target) ;objects)
          (shell ar "rcs" target ;objects))))

(defn- create-buffer-c-impl
  [bytes dest name]
  (def out (file/open dest :w))
  (def chunks (seq [b :in bytes] (string b)))
  (file/write out
              "#include <janet.h>\n"
              "static const unsigned char bytes[] = {"
              (string/join (interpose ", " chunks))
              "};\n\n"
              "const unsigned char *" name "_embed = bytes;\n"
              "size_t " name "_embed_size = sizeof(bytes);\n")
  (file/close out))

(defn- create-buffer-c
  "Inline raw byte file as a c file."
  [source dest name]
  (rule dest [source]
        (print "generating " dest "...")
        (with [f (file/open source :r)]
          (create-buffer-c-impl (:read f :all) dest name))))

(def- root-env (table/getproto (fiber/getenv (fiber/current))))

(defn- modpath-to-meta
  "Get the meta file path (.meta.janet) corresponding to a native module path (.so)."
  [path]
  (string (string/slice path 0 (- (length modext))) "meta.janet"))

(defn- modpath-to-static
  "Get the static library (.a) path corresponding to a native module path (.so)."
  [path]
  (string (string/slice path 0 (- -1 (length modext))) statext))

(defn- create-executable
  "Links an image with libjanet.a (or .lib) to produce an
  executable. Also will try to link native modules into the
  final executable as well."
  [opts source dest]

  # Create executable's janet image
  (def cimage_dest (string dest ".c"))
  (rule dest [source]
        (print "generating executable c source...")
        # Load entry environment and get main function.
        (def entry-env (dofile source))
        (def main ((entry-env 'main) :value))

        # Create marshalling dictionary
        (def mdict (invert (env-lookup root-env)))
        # Load all native modules
        (def prefixes @{})
        (def static-libs @[])
        (loop [[name m] :pairs module/cache
               :let [n (m :native)]
               :when n
               :let [prefix (gensym)]]
          (print "found native " n "...")
          (put prefixes prefix n)
          (array/push static-libs (modpath-to-static n))
          (def oldproto (table/getproto m))
          (table/setproto m nil)
          (loop [[sym value] :pairs (env-lookup m)]
            (put mdict value (symbol prefix sym)))
          (table/setproto m oldproto))

        # Find static modules
        (def declarations @"")
        (def lookup-into-invocations @"")
        (loop [[prefix name] :pairs prefixes]
          (def meta (eval-string (slurp (modpath-to-meta name))))
          (buffer/push-string lookup-into-invocations
                              "    temptab = janet_table(0);\n"
                              "    temptab->proto = env;\n"
                              "    " (meta :static-entry) "(temptab);\n"
                              "    janet_env_lookup_into(lookup, temptab, \""
                              prefix
                              "\", 0);\n\n")
          (buffer/push-string declarations
                              "extern void "
                              (meta :static-entry)
                              "(JanetTable *);\n"))


        # Build image
        (def image (marshal main mdict))
        # Make image byte buffer
        (create-buffer-c-impl image cimage_dest "janet_payload_image")
        # Append main function
        (spit cimage_dest (string
                            "\n"
                            declarations
```

int main(int argc, const char **argv) {
    janet_init();

    /* Get core env */
    JanetTable *env = janet_core_env(NULL);
    JanetTable *lookup = janet_env_lookup(env);
    JanetTable *temptab;
    int handle = janet_gclock();

    /* Load natives into unmarshalling dictionary */

```
                            lookup-into-invocations
```
    /* Unmarshal bytecode */
    Janet marsh_out = janet_unmarshal(
      janet_payload_image_embed,
      janet_payload_image_embed_size,
      0,
      lookup,
      NULL);

    /* Verify the marshalled object is a function */
    if (!janet_checktype(marsh_out, JANET_FUNCTION)) {
      fprintf(stderr, "invalid bytecode image - expected function.");
      return 1;
    }

    /* Collect command line arguments */
    JanetArray *args = janet_array(argc);
    for (int i = 0; i < argc; i++) {
      janet_array_push(args, janet_cstringv(argv[i]));
    }

    /* Create enviornment */
    JanetTable *runtimeEnv = janet_table(0);
    runtimeEnv->proto = env;
    janet_table_put(runtimeEnv, janet_ckeywordv("args"), janet_wrap_array(args));
    janet_gcroot(janet_wrap_table(runtimeEnv));

    /* Unlock GC */
    janet_gcunlock(handle);

    /* Run everything */
    JanetFiber *fiber = janet_fiber(janet_unwrap_function(marsh_out), 64, argc, args->data);
    fiber->env = runtimeEnv;
    Janet out;
    JanetSignal result = janet_continue(fiber, janet_wrap_nil(), &out);
    if (result) {
      janet_stacktrace(fiber, out);
      janet_deinit();
      return result;
    }
    janet_deinit();
    return 0;
}

```) :ab)

# Compile and link final exectable
(do
  (def extra-lflags (case (os/which)
                      :macos ["-ldl" "-lm"]
                      :windows []
                      :linux ["-lm" "-ldl" "-lrt"]
                      #default
                      ["-lm"]))
  (def cc (opt opts :compiler default-compiler))
  (def lflags [;(opt opts :lflags default-lflags) ;extra-lflags])
  (def cflags (getcflags opts))
  (def defines (make-defines (opt opts :defines {})))
  (print "compiling and linking " dest "...")
  (if is-win
    (shell cc ;cflags (string "/OUT:" dest) cimage_dest ;static-libs (libjanet) ;lflags)
    (shell cc ;cflags `-o` dest cimage_dest ;static-libs (libjanet) ;lflags)))))

(defn- abspath
  "Create an absolute path. Does not resolve . and .. (useful for
  generating entries in install manifest file)."
  [path]
  (if (string/has-prefix? absprefix)
    path
    (string (os/cwd) sep path)))

#
# Public utilities
#

(defn find-manifest-dir
  "Get the path to the directory containing manifests for installed
  packages."
  []
  (string (dyn :modpath JANET_MODPATH) sep ".manifests"))

(defn find-manifest
  "Get the full path of a manifest file given a package name."
  [name]
  (string (find-manifest-dir) sep name ".txt"))

(defn find-cache
  "Return the path to the global cache."
  []
  (def path (dyn :modpath JANET_MODPATH))
  (string path sep ".cache"))

(defn uninstall
  "Uninstall bundle named name"
  [name]
  (def manifest (find-manifest name))
  (def f (file/open manifest :r))
  (unless f (print manifest " does not exist") (break))
  (loop [line :iterate (:read f :line)]
    (def path ((string/split "\n" line) 0))
    (print "removing " path)
    (try (rm path) ([err]
                    (unless (= err "No such file or directory")
                      (error err)))))
  (:close f)
  (print "removing " manifest)
  (rm manifest)
  (print "Uninstalled."))

(defn clear-cache
  "Clear the global git cache."
  []
  (def cache (find-cache))
  (print "clearing " cache "...")
  (if is-win
    # Git for windows decided that .git should be hidden and everything in it read-only.
    # This means we can't delete things easily.
    (os/shell (string `rmdir /S /Q "` cache `"`))
    (rm cache)))

(defn install-git
  "Install a bundle from git. If the bundle is already installed, the bundle
  is reinistalled (but not rebuilt if artifacts are cached)."
  [repo]
  (def cache (find-cache))
  (os/mkdir cache)
  (def id (filepath-replace repo))
  (def module-dir (string cache sep id))
  (when (os/mkdir module-dir)
    (os/execute ["git" "clone" repo module-dir] :p))
  (def olddir (os/cwd))
  (os/cd module-dir)
  (try
    (with-dyns [:rules @{}]
      (os/execute ["git" "submodule" "update" "--init" "--recursive"])
      (import-rules "./project.janet")
      (do-rule "install-deps")
      (do-rule "build")
      (do-rule "install"))
    ([err] (print "Error building git repository dependency: " err)))
  (os/cd olddir))

(defn install-rule
  "Add install and uninstall rule for moving file from src into destdir."
  [src destdir]
  (def parts (string/split sep src))
  (def name (last parts))
  (def path (string destdir sep name))
  (array/push (dyn :installed-files) path)
  (add-body "install"
            (try (os/mkdir destdir) ([err] nil))
            (copy src destdir)))

#
# Declaring Artifacts - used in project.janet, targets specifically
# tailored for janet.
#

(defn declare-native
  "Declare a native module. This is a shared library that can be loaded
  dynamically by a janet runtime. This also builds a static libary that
  can be used to bundle janet code and native into a single executable."
  [&keys opts]
  (def sources (opts :source))
  (def name (opts :name))
  (def path (dyn :modpath JANET_MODPATH))

  # Make dynamic module
  (def lname (string "build" sep name modext))
  (loop [src :in sources]
    (compile-c opts src (out-path src ".c" objext)))
  (def objects (map (fn [path] (out-path path ".c" objext)) sources))
  (when-let [embedded (opts :embedded)]
            (loop [src :in embedded]
              (def c-src (out-path src ".janet" ".janet.c"))
              (def o-src (out-path src ".janet" (if is-win ".janet.obj" ".janet.o")))
              (array/push objects o-src)
              (create-buffer-c src c-src (embed-name src))
              (compile-c opts c-src o-src)))
  (link-c opts lname ;objects)
  (add-dep "build" lname)
  (install-rule lname path)

  # Add meta file
  (def metaname (modpath-to-meta lname))
  (def ename (entry-name name))
  (rule metaname []
        (print "generating meta file " metaname "...")
        (spit metaname (string/format
                         "# Metadata for static library %s\n\n%.20p"
                         (string name statext)
                         {:static-entry ename
                          :lflags (opts :lflags)})))
  (add-dep "build" metaname)
  (install-rule metaname path)

  # Make static module
  (unless (dyn :nostatic)
    (def sname (string "build" sep name statext))
    (def opts (merge @{:entry-name ename} opts))
    (def sobjext (string ".static" objext))
    (def sjobjext (string ".janet" sobjext))
    (loop [src :in sources]
      (compile-c opts src (out-path src ".c" sobjext) true))
    (def sobjects (map (fn [path] (out-path path ".c" sobjext)) sources))
    (when-let [embedded (opts :embedded)]
              (loop [src :in embedded]
                (def c-src (out-path src ".janet" ".janet.c"))
                (def o-src (out-path src ".janet" sjobjext))
                (array/push sobjects o-src)
                # Buffer c-src is already declared by dynamic module
                (compile-c opts c-src o-src true)))
    (archive-c opts sname ;sobjects)
    (add-dep "build" sname)
    (install-rule sname path)))

(defn declare-source
  "Create a Janet modules. This does not actually build the module(s),
  but registers it for packaging and installation."
  [&keys {:source sources}]
  (def path (dyn :modpath JANET_MODPATH))
  (if (bytes? sources)
    (install-rule sources path)
    (each s sources
      (install-rule s path))))

(defn declare-bin
  "Declare a generic file to be installed as an executable."
  [&keys {:main main}]
  (install-rule main (dyn :binpath JANET_BINPATH)))

(defn declare-executable
  "Declare a janet file to be the entry of a standalone executable program. The entry
  file is evaluated and a main function is looked for in the entry file. This function
  is marshalled into bytecode which is then embedded in a final executable for distribution.\n\n
  This executable can be installed as well to the --binpath given."
  [&keys {:install install :name name :entry entry}]
  (def name (if is-win (string name ".exe") name))
  (def dest (string "build" sep name))
  (create-executable @{} entry dest)
  (add-dep "build" dest)
  (when install
    (install-rule dest (dyn :binpath JANET_BINPATH))))

(defn declare-binscript
  "Declare a janet file to be installed as an executable script. Creates
  a shim on windows."
  [&keys opts]
  (def main (opts :main))
  (def binpath (dyn :binpath JANET_BINPATH))
  (install-rule main binpath)
  # Create a dud batch file when on windows.
  (when is-win
    (def name (last (string/split sep main)))
    (def bat (string "@echo off\r\njanet %~dp0\\" name "%*"))
    (def newname (string binpath sep name ".bat"))
    (add-body "install"
              (spit newname bat))
    (add-body "uninstall"
              (os/rm newname))))

(defn declare-archive
  "Build a janet archive. This is a file that bundles together many janet
  scripts into a janet image. This file can the be moved to any machine with
  a janet vm and the required dependencies and run there."
  [&keys opts]
  (def entry (opts :entry))
  (def name (opts :name))
  (def iname (string "build" sep name ".jimage"))
  (rule iname (or (opts :deps) [])
        (spit iname (make-image (require entry))))
  (def path (dyn :modpath JANET_MODPATH))
  (add-dep "build" iname)
  (install-rule iname path))

(defn declare-project
  "Define your project metadata. This should
  be the first declaration in a project.janet file.
  Also sets up basic phony targets like clean, build, test, etc."
  [&keys meta]
  (setdyn :project meta)

  (def installed-files @[])
  (def manifests (find-manifest-dir))
  (def manifest (find-manifest (meta :name)))
  (setdyn :manifest manifest)
  (setdyn :manifest-dir manifests)
  (setdyn :installed-files installed-files)

  (rule "./build" [] (os/mkdir "build"))
  (phony "build" ["./build"])

  (phony "manifest" []
         (print "generating " manifest "...")
         (os/mkdir manifests)
         (spit manifest (string (string/join installed-files "\n") "\n")))
  (phony "install" ["uninstall" "build" "manifest"]
         (print "Installed as '" (meta :name) "'."))

  (phony "install-deps" []
         (if-let [deps (meta :dependencies)]
           (each dep deps
             (install-git dep))
           (print "no dependencies found")))

  (phony "uninstall" []
         (uninstall (meta :name)))

  (phony "clean" []
         (when (os/stat "./build" :mode)
           (rm "build")
           (print "Deleted build directory.")))

  (phony "test" ["build"]
         (defn dodir
           [dir]
           (each sub (os/dir dir)
             (def ndir (string dir sep sub))
             (case (os/stat ndir :mode)
               :file (when (string/has-suffix? ".janet" ndir)
                       (print "running " ndir " ...")
                       (dofile ndir :exit true))
               :directory (dodir ndir))))
         (dodir "test")
         (print "All tests passed.")))

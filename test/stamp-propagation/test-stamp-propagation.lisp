;; NB: This test file is supposed to work using old defsystems:
;; not just ASDF 2.26, but also legacy defsystems from Allegro, Genera, LispWorks

(unless (find-package :asdf-test)
  (load (merge-pathnames
         (make-pathname :defaults *load-pathname*
                        :name "script-support" :directory '(:relative :back))
         *load-pathname*)))

(unless (find-package :asdf)
  (asdf-test::load-asdf)
  (asdf-test::frob-packages))

(in-package :asdf-test)

(DBG :foo)

(defparameter *eval-notes* ())
(defun note-eval (when file)
  (format t "~&XXX ~S ~S~%" when file)
  (push `(,when ,file #|,*load-pathname* ,*compile-file-pathname*|#) *eval-notes*))
(defun eval-notes ()
  (prog1 (reverse *eval-notes*) (setf *eval-notes* nil)))
(defmacro eval-note (&optional x)
  `(progn
     (eval-when (:compile-toplevel) (note-eval :compile-toplevel ',x))
     (eval-when (:load-toplevel) (note-eval :load-toplevel ',x))
     (eval-when (:execute) (note-eval :execute ',x))))


(eval-note :tsp)

(defvar *tsp* (asdf::pathname-directory-pathname *load-pathname*))
(defun lisppath (filename) (asdf::subpathname *tsp* filename))
(defun faslpath (lisppath &optional (defsystem *default-defsystem*))
  (funcall
   (if (and (eq defsystem :asdf) (fboundp 'asdf::compile-file-pathname*))
       'asdf::compile-file-pathname*
       'compile-file-pathname)
   (etypecase lisppath
     (pathname lisppath)
     (string (lisppath lisppath)))))

(defvar asdf::*asdf-cache* nil) ;; if defparameter instead of defvar, disable any surrounding cache

(defun use-cache-p (defsystem)
  (and (eq defsystem :asdf)
       (asdf:version-satisfies (asdf:asdf-version) "2.27")
       asdf::*asdf-cache*))

#+allegro
(excl:defsystem :test-stamp-propagation
  (:default-pathname #.*tsp*)
  (:definitions
   "file1.lisp"
   "file2.lisp"))

#+genera
(sct:defsystem :test-stamp-propagation
  (:default-pathname #.*tsp* :patchable nil)
  (:definitions
   "file1.lisp"
   "file2.lisp"))

#+lispworks
(scm:defsystem :test-stamp-propagation
  (:default-pathname #.*tsp*)
  :members ("file1" "file2")
  :rules ((:in-order-to :compile ("file2")
           (:caused-by (:compile "file1"))
           (:requires (:load "file1")))))

#+asdf
(asdf:defsystem :test-stamp-propagation
  :pathname #.*tsp* :source-file nil
  :serial t
  :components
  ((:file "file1")
   (:file "file2")))

#+mk-defsystem
(mk:defsystem :test-stamp-propagation
  (:default-pathname #.*tsp* :patchable nil)
  (:serial
   "file1.lisp"
   "file2.lisp"))

(defparameter *defsystems* '(#+(or allegro genera lispworks) :native
                             #+mk-defsystem :mk-defsystem
                             #+asdf :asdf))

(defvar *default-defsystem* (first *defsystems*))

(defun reload (&optional (defsystem *default-defsystem*))
  (format t "~&ASDF-CACHE ~S~%" asdf::*asdf-cache*)
  (setf *eval-notes* nil)
  (setf *compile-verbose* t *load-verbose* t)
  (ecase defsystem
    #+asdf
    (:asdf
     (note-eval :compiling :system)
     (unless (use-cache-p :asdf) ;; faking the cache only works for one plan
       (asdf:compile-system :test-stamp-propagation))
     (note-eval :loading :system)
     (asdf:load-system :test-stamp-propagation))
    #+mk-defsystem
    (:mk-defsystem
     (note-eval :compiling :system)
     (mk:compile-system :test-stamp-propagation)
     (note-eval :loading :system)
     (mk:load-system :test-stamp-propagation))
    (:native
     (note-eval :compiling :system)
     #+allegro (excl:compile-system :test-stamp-propagation)
     #+lispworks (scm:compile-system :test-stamp-propagation)
     #+genera (sct:compile-system :test-stamp-propagation)
     (note-eval :loading :system)
     #+allegro (excl:load-system :test-stamp-propagation)
     #+lispworks (scm:load-system :test-stamp-propagation)
     #+genera (sct:load-system :test-stamp-propagation)))
  (let ((n (eval-notes)))
    (format t "~&EVAL-NOTES ~S~%" n)
    n))

(defun touch (filename)
  #+genera filename ;; TODO: do something with it!
  #-genera
  (uiop:run-program `("touch" ,(native-namestring filename))
                    :output t :error-output t))

(defun clear-fasls (&optional (defsystem *default-defsystem*))
  (loop :for file :in '("file1.lisp" "file2.lisp")
        :for faslpath = (faslpath file defsystem)
        :do (if (and (eq defsystem :asdf) asdf::*asdf-cache*)
                (mark-file-deleted faslpath)
                (delete-file-if-exists faslpath))))

(defun sanitize-log (log)
  (remove-duplicates
   (remove '(:loading :system) log :test 'equal)
   :test 'equal :from-end t))

(defun test-defsystem (&optional (defsystem *default-defsystem*))
  (format t "~&Testing stamp propagation by defsystem ~S~%" defsystem)
  #+allegro (progn (DBG "removing any old fasls from another flavor of allegro")
                   (clear-fasls defsystem))
  (DBG "loading system")
  (reload defsystem)
  (cond
    ((use-cache-p defsystem)
     (DBG "marking all files old but first source file, and reloading")
     (let ((tf2 (file-write-date (faslpath "file2.lisp"))))
       (touch-file (lisppath "file1.lisp") :timestamp tf2 :offset 0)
       (touch-file (faslpath "file1.lisp") :timestamp tf2 :offset -2000)
       (touch-file (lisppath "file2.lisp") :timestamp tf2 :offset -5000)
       (touch-file (faslpath "file2.lisp") :timestamp tf2 :offset -1000)))
    (t
     (DBG "touching first source file and reloading")
     (sleep #-os-windows 3 #+os-windows 5)
     (touch (lisppath "file1.lisp"))))
  (DBG "defsystem should recompile & reload everything")
  (assert-equal (sanitize-log (reload defsystem))
                '((:compiling :system) (:compile-toplevel :file1) (:load-toplevel :file1)
                  (:compile-toplevel :file2) (:load-toplevel :file2)))
  (cond
    ((use-cache-p defsystem)
     (DBG "marking the old fasl new, the second one up to date")
     (let ((tf2 (file-write-date (faslpath "file2.lisp"))))
       (touch-file (lisppath "file1.lisp") :timestamp tf2 :offset 0)
       (touch-file (faslpath "file1.lisp") :timestamp tf2 :offset 500)
       (touch-file (lisppath "file2.lisp") :timestamp tf2 :offset 0)
       (touch-file (faslpath "file2.lisp") :timestamp tf2 :offset 0)))
    (t
     (DBG "touching first fasl file and reloading")
     (sleep #-os-windows 3 #+os-windows 5)
     (touch (faslpath "file1.lisp" defsystem))))
  (DBG "defsystem should reload it, recompile & reload the other")
  (assert-equal (sanitize-log (reload defsystem))
                '((:compiling :system) (:load-toplevel :file1)
                  (:compile-toplevel :file2) (:load-toplevel :file2)))
  (DBG "cleaning up")
  (clear-fasls defsystem))


#-(or abcl xcl) ;; TODO: figure out why ABCL and XCL fail to recompile anything.
(test-defsystem :asdf)

#+(or genera lispworks)
(test-defsystem :native)

#+(or allegro)
(signals error (test-defsystem :native))

#+mkdefsystem
(signals error (test-defsystem :mk-defsystem))

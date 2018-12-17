;;;; utilities.lisp

(in-package #:april)

(define-symbol-macro this-idiom (local-idiom april))
(define-symbol-macro index-origin (of-state this-idiom :count-from))
(define-symbol-macro atomic-vector (of-state this-idiom :atomic-vector))

(defun enclose (item)
  "Enclose non-array values, passing through arguments that are already arrays."
  (if (vectorp item)
      item (vector item)))

(defun disclose-atom (item)
  "If the argument is a non-nested array with only one member, disclose it, otherwise do nothing."
  (if (and (not (stringp item))
	   (arrayp item)
	   (is-unitary item)
	   (not (arrayp (aref item 0))))
      (row-major-aref item 0)
      item))

(defun array-to-nested-vector (array)
  "Convert an array to a nested vector. Useful for applications such as JSON conversion where multidimensional arrays must be converted to nested vectors."
  (aops:each (lambda (member)
	       (if (and (arrayp member)
			(< 1 (rank member)))
		   (array-to-nested-vector member)
		   member))
	     (aops:split array 1)))

(defmacro avector (&rest items)
  "This macro returns an APL vector, disclosing data within that are meant to be individual atoms."
  (cons 'vector (loop :for item :in items :collect (if (and (listp item)
							    (eql 'avatom (first item)))
						       `(disclose ,item)
						       item))))

(defmacro avatom (item)
  "An APL vector atom. This passthrough macro provides information to the (avector) macro."
  item)

(defun apply-scalar (function alpha &optional omega)
  "Apply a scalar function across objects as appropriate in APL. Handles scalars as well as nested and multidimensional arrays."
  (if (not omega)
      (let ((omega alpha))
	(if (arrayp omega)
	    (labels ((apply-fn (arg) (if (arrayp arg) (aops:each #'apply-fn arg)
					 (funcall function arg))))
	      (aops:each #'apply-fn omega))
	    (funcall function omega)))
      (let* ((alpha-scalar? (not (arrayp alpha)))
	     (omega-scalar? (not (arrayp omega)))
	     (alpha-unitary? (or alpha-scalar? (is-unitary alpha)))
	     (omega-unitary? (or omega-scalar? (is-unitary omega))))
	(cond ((and alpha-scalar? omega-scalar?)
	       (funcall function alpha omega))
	      ((and alpha-scalar? omega-unitary?)
	       (disclose-atom (aops:each (lambda (a o) (apply-scalar function a o))
					 (vector alpha) omega)))
	      ((and alpha-unitary? omega-scalar?)
	       (disclose-atom (aops:each (lambda (a o) (apply-scalar function a o))
					 alpha (vector omega))))
	      ((and alpha-unitary? omega-unitary?)
	       (aops:each (lambda (a o) (apply-scalar function a o))
			  alpha omega))
	      ((not (or alpha-unitary? omega-unitary? alpha-scalar? omega-scalar?))
	       (if (loop :for dimension :in (mapcar #'= (dims alpha) (dims omega))
		      :always dimension)
		   (aops:each (lambda (alpha omega) (apply-scalar function alpha omega))
			      alpha omega)
		   (error "Array size mismatch.")))
	      (t (labels ((scan-over (element)
			    (if (arrayp element)
				(aops:each #'scan-over element)
				(apply (lambda (left right) (apply-scalar function left right))
				       (cond (alpha-scalar? (list alpha element))
					     (alpha-unitary? (list (disclose alpha) element))
					     (omega-scalar? (list element omega))
					     (omega-unitary? (list element (disclose omega))))))))
		   (aops:each #'scan-over (if (or alpha-scalar? alpha-unitary?)
					      omega alpha))))))))

(defun numeric-string-p (string)
  "Checks whether the argument is a numeric string."
  (handler-case (progn (parse-apl-number-string string) t)
    (condition () nil)))

(defun parse-apl-number-string (number-string &optional imaginary-component)
  "Parse an APL numeric string into a Lisp value, handling high minus signs and the J-notation for complex numbers."
  (let ((nstring (string-upcase number-string)))
    (if (and (not imaginary-component)
	     (find #\J nstring))
	(let ((halves (cl-ppcre:split "J" nstring)))
	  (if (and (= 2 (length halves))
		   (< 0 (length (first halves)))
		   (< 0 (length (second halves))))
	      (complex (parse-apl-number-string (first halves) t)
		       (parse-apl-number-string (second halves) t))))
	;; the macron character is converted to the minus sign
	(parse-number:parse-number (regex-replace-all "[¯]" nstring "-")))))

(defun format-value (idiom-name meta element)
  "Convert a token string into an APL value, paying heed to APL's native ⍺, ⍵ and ⍬ variables."
  (cond ((and (vectorp element)
	      (string= element "⍬"))
	 ;; APL's "zilde" character translates to an empty vector
 	 (make-array (list 0)))
	((and (vectorp element)
	      (or (string= element "⍺")
		  (string= element "⍵")))
	 ;; alpha and omega characters are directly changed to symbols
 	 (intern element idiom-name))
	((numeric-string-p element)
	 (parse-apl-number-string element))
	((or (and (char= #\" (aref element 0))
		  (char= #\" (aref element (1- (length element)))))
	     (and (char= #\' (aref element 0))
		  (char= #\' (aref element (1- (length element))))))
	 ;; strings are converted to Lisp strings and passed through
	 (subseq element 1 (1- (length element))))
	((stringp element)
	 ;; variable references are converted into generated symbols from the variable table or,
	 ;; if no reference is found in that table, a new reference is created there and a new symbol
	 ;; is generated
	 (if (not (gethash :variables meta))
	     (setf (gethash :variables meta)
		   (make-hash-table :test #'eq)))
	 (let ((variable-found (gethash (intern element "KEYWORD")
					(gethash :variables meta))))
	   (if variable-found variable-found
	       ;; create a new variable if no variable is found matching the string
	       (setf (gethash (intern element "KEYWORD")
			      (gethash :variables meta))
		     (gensym)))))
	(t element)))

(defun process-output-vector (items)
  "Process items in a vector to be generated by the compiler, wrapping any array references in aplSymbol so that they are disclosed. This does not apply if the output vector is unitary (length 1)."
  (loop :for item :in items :collect (if (and (< 1 (length items))
					      (listp item) (eql 'aref-eliding (first item)))
					 (list 'disclose item)
					 item)))

(defmacro verify-function (reference)
  "Verify that a function exists, either in the form of a character-referenced function, an explicit inline function or a user-created symbol referencing a function."
  `(if (characterp ,reference)
       (or (of-functions this-idiom ,reference :monadic)
	   (of-functions this-idiom ,reference :dyadic)
	   (of-functions this-idiom ,reference :symbolic))
       (if (symbolp ,reference)
	   (if (gethash ,reference (gethash :functions workspace))
	       ,reference)
	   (if (and (listp ,reference)
		    (eql 'lambda (first ,reference)))
	       ,reference))))

(defmacro resolve-function (mode reference)
  "Retrieve function content for a functional character, pass through an explicit or symbol-referenced function, or return nil if the function doesn't exist."
  `(if (characterp ,reference)
       (of-functions this-idiom ,reference ,mode)
       (if (symbolp ,reference)
	   (if (gethash ,reference (gethash :functions workspace))
	       ,reference)
	   (if (and (listp ,reference)
		    (eql 'lambda (first ,reference)))
	       ,reference))))

(defmacro resolve-operator (mode reference)
  "Retrive an operator's composing function."
  `(of-operators this-idiom ,reference ,mode))

(defun extract-axes (process tokens &optional axes)
  "Given a list of tokens starting with axis specifications, build the code for the axis specifications to be applied to the subsequent function or value."
  (if (and (listp (first tokens))
	   (eq :axes (caar tokens)))
      (extract-axes process (rest tokens)
		    (cons (loop :for axis :in (cdar tokens)
			     :collect (multiple-value-bind (item item-props remaining)
					  (funcall process axis)
					(declare (ignore remaining))
					;; allow either a null item (representing an elided axis) or an array
					(if (or (not item)
						(eq :array (first (getf item-props :type))))
					    item (error "Invalid axis."))))
			  axes))
      (values axes (first tokens)
	      (rest tokens))))

(defmacro apl-call (symbol function &rest arguments)
  "Call an APL function with one or two arguments. Compose successive scalar functions into bigger functions for more efficiency."
  (declare (ignore symbol))
  (let ((arg (gensym)))
    (flet ((is-scalar (form) (and (listp form) (eql 'scalar-function (first form))))
	   (expand-monadic (fn argument)
	     (let ((arg-expanded (macroexpand argument)))
	       (if (and (listp arg-expanded)
			(eql 'apply-scalar (first arg-expanded))
			(not (fourth arg-expanded)))
		   (let ((innerfn (second arg-expanded)))
		     (list (if (not (eql 'lambda (first innerfn)))
			       `(lambda (,arg) (funcall ,fn (funcall ,innerfn ,arg)))
			       (list (first innerfn) (second innerfn)
				     `(funcall ,fn ,(third innerfn))))
			   (third arg-expanded)))
		   (list fn argument))))
	   (expand-dyadic (fn is-first arg1 arg2)
	     (let* ((arg-expanded (macroexpand (if is-first arg1 arg2))))
	       (if (and (listp arg-expanded)
			(eql 'apply-scalar (first arg-expanded)))
		   (let ((innerfn (second arg-expanded)))
		     (list (if (not (eql 'lambda (first innerfn)))
			       `(lambda (,arg) (funcall ,fn ,@(if (not is-first) (list arg1))
							(funcall ,innerfn ,arg)
							,@(if is-first (list arg2))))
			       (list (first innerfn) (second innerfn)
				     `(funcall ,fn ,@(if (not is-first) (list arg1))
					       ,(third innerfn)
					       ,@(if is-first (list arg2)))))
			   (third arg-expanded)))))))
      (let ((scalar-fn (is-scalar function)))
	(append (list (if scalar-fn 'apply-scalar 'funcall))
		(cond ((and scalar-fn (not (second arguments)))
		       ;; compose monadic functions if the argument is the output of another scalar function
		       (expand-monadic function (first arguments)))
		      ((and scalar-fn (second arguments)
		      	    (listp (first arguments))
		      	    (eql 'avector (caar arguments))
		      	    (not (third (first arguments)))
		      	    (numberp (cadar arguments)))
		       ;; compose dyadic functions if the first argument is a scalar numeric value
		       ;; and the other argument is the output of a scalar function
		       (let ((expanded (expand-dyadic function nil (cadar arguments) (second arguments))))
		      	 (or expanded `((lambda (,arg) (funcall ,function ,(cadar arguments) ,arg))
		      			,(macroexpand (second arguments))))))
		      ((and scalar-fn (second arguments)
		      	    (listp (second arguments))
		      	    (eql 'avector (caadr arguments))
		      	    (not (third (second arguments)))
		      	    (numberp (cadadr arguments)))
		       ;; same as above if the numeric argument is reversed
		       (let ((expanded (expand-dyadic function t (first arguments) (cadadr arguments))))
		      	 (or expanded `((lambda (,arg) (funcall ,function ,arg ,(cadadr arguments)))
		      			,(macroexpand (first arguments))))))
		      ;; otherwise, just list the function and its arguments
		      (t (cons function arguments))))))))

;; (defmacro apl-call (symbol function &rest arguments)
;;   (declare (ignore symbol))
;;   `(,(if (and (listp function)
;; 	      (eql 'scalar-function (first function)))
;; 	 'apply-scalar 'funcall)
;;      ,function  ,@arguments))

(defmacro scalar-function (function)
  "Wrap a scalar function. This is a passthrough macro used by the scalar composition system in (apl-call)."
  (if (symbolp function)
      `(function ,function)
      function))

(defun validate-arg-unitary (value)
  "Verify that a form like (vector 5) represents a unitary value."
  (or (symbolp value)
      (numberp value)
      (and (listp value)
	   (or (not (eql 'vector (first value)))
	       (not (third value))))))

(defmacro or-functional-character (reference symbol)
  `(if (not (characterp ,reference))
       ,symbol (intern (string-upcase ,reference))))

(defun enclose-axes (body axis-sets &key (set nil))
  "Apply axes to an array, with the ability to handle multiple sets of axes as in (6 8 5⍴⍳9)[1 4;;2 1][1;2 4 5;]."
  (let ((axes (first axis-sets)))
    (if (not axis-sets)
	body (enclose-axes
	      `(aref-eliding ,body (mapcar (lambda (array) (if array (apply-scalar #'- array index-origin)))
					   (list ,@axes))
			     ,@(if set (list :set set)))
	      (rest axis-sets)))))

(defun output-value (space form &optional properties)
  "Express an APL value in the form of an explicit array specification or a symbol representing an array, supporting axis arguments."
  (flet ((apply-props (item form-props)
	   (let ((form-props (if (listp (first form-props))
				 (first form-props)
				 form-props)))
	     ;; wrap output symbols in the (avatom) form so that they are disclosed
	     ;; if part of an APL vector (avector)
	     (funcall (if (not (symbolp item))
			  #'identity (lambda (item) `(avatom ,item)))
		      (if (getf form-props :axes)
			  (enclose-axes item (getf form-props :axes))
			  item)))))
    (let ((properties (reverse properties)))
      (if form (if (listp form)
		   (if (not (or (numberp (first form))
				(listp (first form))
				(stringp (first form))
				(eql '⍺ (first form))
				(eql '⍵ (first form))
				(and (symbolp (first form))
				     (or (gethash (string (first form))
						  (gethash :values space))
					 (not (loop :for key :being :the :hash-keys :of (gethash :variables space)
						 :never (eql (first form)
							     (gethash key (gethash :variables space)))))))))
		       (if (= 1 (length properties))
			   (apply-props form (first properties))
			   (mapcar #'apply-props form properties))
		       `(avector ,@(mapcar #'apply-props form properties)))
		   (if (not (numberp form))
		       (apply-props form properties)
		       `(avector ,form)))))))

(defun output-function (form)
  "Express an APL inline function like {⍵+5}."
  `(lambda (⍵ &optional ⍺)
     (declare (ignorable ⍺))
     (let ((⍵ (disclose ⍵)))
       (declare (ignorable ⍵))
       ,form)))

(defun left-invert-matrix (in-matrix)
  "Perform left inversion of matrix, used in the ⌹ function."
  (let* ((input (if (= 2 (rank in-matrix))
		    in-matrix (make-array (list (length in-matrix) 1)
					  :element-type (element-type in-matrix)
					  :initial-contents (loop :for i :from 0 :to (1- (length in-matrix))
							       :collect (list (aref in-matrix i))))))
	 (result (array-inner-product
		  (invert-matrix (array-inner-product (aops:permute (reverse (iota (rank input)))
								    input)
						      input (lambda (arg1 arg2) (apply-scalar #'* arg1 arg2))
						      #'+))
		  (aops:permute (reverse (iota (rank input)))
				input)
		  (lambda (arg1 arg2) (apply-scalar #'* arg1 arg2))
		  #'+)))
    (if (= 1 (rank in-matrix))
	(aref (aops:split result 1) 0)
	result)))

(defun over-operator-template (axes function &key (first-axis nil) (for-vector nil) (for-array nil))
  "Build a function to generate code applying functions over arrays, as for APL's reduce and scan operators."
  `(lambda (omega)
     ,(let ((wrapped-function `(lambda (omega alpha) (apl-call :fn ,function omega alpha))))
	`(let ((new-array (copy-array omega)))
	   ;; wrap the result in an extra array layer if it is already an enclosed array of rank > 1,
	   ;; this ensures that the returned result will be enclosed
	   (funcall (lambda (item) (if (= 1 (array-depth omega))
				       item (vector item)))
		    (if (vectorp new-array)
			(funcall ,for-vector ,wrapped-function new-array)
			(funcall ,for-array ,wrapped-function new-array
				 ,(if axes `(1- (disclose ,(first axes)))
				      (if first-axis 0 `(1- (rank new-array)))))))))))

(defun april-function-glyph-processor (type glyph spec)
  "Convert a Vex function specification for April into a set of lexicon elements, forms and functions that will make up part of the April idiom object used to compile the language."
  (let ((type (intern (string-upcase type) "KEYWORD"))
	(function-type (intern (string-upcase (first spec)) "KEYWORD"))
	(spec-body (rest spec)))
    (cond ((eq :symbolic function-type)
	   `(,glyph :lexicons (:functions :symbolic-functions)
		    :functions (:symbolic ,(first spec-body))))
	  ((keywordp (first spec-body))
	   ;; if this is a simple scalar declaration passing through another function
	   `(,glyph :lexicons (:functions :scalar-functions :monadic-functions :scalar-monadic-functions
					  ,@(if (not (eq :monadic function-type))
						(list :dyadic-functions :scalar-dyadic-functions)))
		    :functions ,(append (if (or (eq :ambivalent function-type)
						(eq :monadic function-type))
					    (list :monadic `(scalar-function ,(second spec-body))))
					(if (or (eq :ambivalent function-type)
						(eq :dyadic function-type))
					    (list :dyadic `(scalar-function ,(first (last spec-body))))))))
	  (t `(,glyph :lexicons ,(cond ((eq :functions type)
					`(:functions ,@(if (eq :ambivalent function-type)
							   (list :monadic-functions :dyadic-functions)
							   (list (intern (string-upcase
									  (concatenate 'string
										       (string function-type)
										       "-" (string type)))
									 "KEYWORD")))
						     ,@(if (and (or (eq :ambivalent function-type)
								    (eq :monadic function-type))
								(eql 'scalar-function (caar spec-body)))
							   (list :scalar-functions :scalar-monadic-functions))
						     ,@(if (or (and (eq :dyadic function-type)
								    (eql 'scalar-function (caar spec-body)))
							       (and (eq :ambivalent function-type)
								    (eql 'scalar-function (caadr spec-body))))
							   (list :scalar-functions :scalar-dyadic-functions))))
				       ((eq :operators type)
					`(:operators ,(if (eq :lateral function-type)
							    :lateral-operators :pivotal-operators))))
		      ,@(cond ((eq :functions type)
			       `(:functions ,(append (if (or (eq :ambivalent function-type)
							     (eq :monadic function-type))
							 (list :monadic (first spec-body)))
						     (if (eq :ambivalent function-type)
							 (list :dyadic (second spec-body))
							 (if (eq :dyadic function-type)
							     (list :dyadic (first spec-body))))
						     (if (eq :symbolic function-type)
							 (list :symbolic (first spec-body))))))
			      ((eq :operators type)
			       `(:operators ,(first spec-body)))))))))

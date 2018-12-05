;;;; utilities.lisp

(in-package #:april)

(define-symbol-macro index-origin (of-state (local-idiom april) :count-from))
(define-symbol-macro atomic-vector (of-state (local-idiom april) :atomic-vector))

(defparameter *circular-functions*
  ;; APL's set of circular functions called using the ○ function with a left argument
  (vector (lambda (input) (exp (* input #C(0 1))))
	  (lambda (input) (* input #C(0 1)))
	  #'conjugate #'values (lambda (input) (sqrt (- -1 (* 2 input))))
	  #'atanh #'acosh #'asinh (lambda (input) (* (1+ input) (sqrt (/ (1+ input) (1- input)))))
	  #'atan #'acos #'asin (lambda (input) (sqrt (- 1 (* 2 input))))
	  #'sin #'cos #'tan (lambda (input) (sqrt (1+ (* 2 input))))
	  #'sinh #'cosh #'tanh (lambda (input) (sqrt (- -1 (* 2 input))))
	  #'realpart #'abs #'imagpart #'phase))

(defun array-to-nested-vector (array)
  "Convert an array to a nested vector. Useful for applications such as JSON conversion where multidimensional arrays must be converted to nested vectors."
  (aops:each (lambda (member)
	       (if (and (arrayp member)
			(< 1 (rank member)))
		   (array-to-nested-vector member)
		   member))
	     (aops:split array 1)))

(defmacro avector (&rest items)
  (cons 'vector (loop for item in items
		   collect (if (and (listp item)
				    (eql 'avatom (first item)))
			       `(disclose ,item)
			       item))))

(defmacro avatom (item)
  item)

(defun apply-scalar-monadic (function omega)
  "Apply a scalar function across a single arguments, iterating over multidimensional and nested arrays."
  (if (arrayp omega)
      (labels ((apply-fn (arg) (if (arrayp arg)
				   (aops:each #'apply-fn arg)
				   (funcall function arg))))
	(aops:each #'apply-fn omega))
      (funcall function omega)))

(defun apply-scalar-dyadic (function alpha omega)
  "Apply a scalar function across objects as appropriate in APL. Handles scalars as well as nested and multidimensional arrays."
  (let* ((alpha-scalar? (not (arrayp alpha)))
	 (omega-scalar? (not (arrayp omega)))
	 (alpha-unitary? (and (not alpha-scalar?)
			      (vectorp alpha)
			      (= 1 (length alpha))))
	 (omega-unitary? (and (not omega-scalar?)
			      (vectorp omega)
			      (= 1 (length omega)))))
    (cond ((and alpha-scalar? omega-scalar?)
	   (funcall function alpha omega))
	  ((and alpha-scalar? omega-unitary?)
	   (aops:each (lambda (alpha omega) (apply-scalar-dyadic function alpha omega))
		      (vector alpha)
		      omega))
	  ((and alpha-unitary? omega-scalar?)
	   (aops:each (lambda (alpha omega) (apply-scalar-dyadic function alpha omega))
		      alpha (vector omega)))
	  ((and alpha-unitary? omega-unitary?)
	   (aops:each (lambda (alpha omega) (apply-scalar-dyadic function alpha omega))
		      alpha omega))
	  ((and (not alpha-unitary?)
		(not omega-unitary?)
		(not alpha-scalar?)
		(not omega-scalar?))
	   (if (loop for dimension in (funcall (lambda (a o) (mapcar #'= a o))
					       (dims alpha)
					       (dims omega))
		  always dimension)
	       (aops:each (lambda (alpha omega) (apply-scalar-dyadic function alpha omega))
			  alpha omega)
	       (error "Array size mismatch.")))
	  (t (labels ((scan-over (element)
			(if (arrayp element)
			    (aops:each #'scan-over element)
			    (apply (lambda (left right) (apply-scalar-dyadic function left right))
				   (cond (alpha-scalar? (list alpha element))
					 (alpha-unitary? (list (aref alpha 0)
							       element))
					 (omega-scalar? (list element omega))
					 (omega-unitary? (list element (aref omega 0))))))))
	       (aops:each #'scan-over (if (or alpha-scalar? alpha-unitary?)
					  omega alpha)))))))

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
	;; the macron character is converted to the high minus sign
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

(defun format-array (values)
  "Format an APL array, passing through values that are already arrays."
  (if (or (stringp (first values))
	  (symbolp (first values))
	  (and (not (second values))
	       (or (listp (first values))
		   (functionp (first values)))))
      ;; if the first item is a list (i.e. code to generate an array of some kind),
      ;; pass it through with no changes. Also pass through strings, which are already arrays,
      ;; any symbols
      (first values)
      `(make-array (list ,(length values))
		   :initial-contents (list ,@values))))

(defun format-function (idiom-name content)
  "Format an APL function, reversing the order of alpha and omega arguments to reflect the argument order of Lisp as opposed to APL."
  (let ((⍺ (intern "⍺" idiom-name))
	(⍵ (intern "⍵" idiom-name)))
    (lambda (meta axes omega &optional alpha)
      (declare (ignorable meta axes))
      `(funcall (lambda (,⍵ &optional ,⍺)
		  (declare (ignorable ,⍺ ,⍵))
		  ,content)
		;; note: enclosing the arguments slows performance when iterating over many values,
		;; but there is no other simple way to ensure the arguments received are arrays
		(enclose ,(macroexpand omega))
		,@(if alpha (list (list 'enclose (macroexpand alpha))))))))

(defun enclose (item)
  "Enclose non-array values, passing through arguments that are already arrays."
  (if (arrayp item)
      item (vector item)))

(defun process-output-vector (items)
  "Process items in a vector to be generated by the compiler, wrapping any array references in aplSymbol so that they are disclosed. This does not apply if the output vector is unitary (length 1)."
  (loop for item in items collect (if (and (< 1 (length items))
					   (listp item)
					   (eql 'aref-eliding (first item)))
				      (list 'disclose item)
				      item)))

(defun extract-axes (process tokens &optional axes)
  "Given a list of tokens starting with axis specifications, build the code for the axis specifications to be applied to the subsequent function or value."
  ;;(print (list :to tokens))
  (if (and (listp (first tokens))
	   (eq :axes (caar tokens)))
      (extract-axes process (rest tokens)
		    (cons (loop for axis in (cdar tokens)
			     collect (multiple-value-bind (item item-props remaining)
					 (funcall process axis)
				       ;; allow either a null item (representing an elided axis) or an array
				       (if (or (not item)
					       (eq :array (first (getf item-props :type))))
					   item (error "Invalid axis."))))
			  axes))
      (values axes (first tokens)
	      (rest tokens))))

(defmacro apl-call (function &rest arguments)
  `(,(if (and (listp function)
	      (eql 'scalar-function (first function)))
	 (if (= 1 (length arguments))
	     'apply-scalar-monadic 'apply-scalar-dyadic)
	 'funcall)
     ,@(if (and (not (second arguments))
		(listp (first arguments)))
	   (let ((arg-expanded (macroexpand (first arguments))))
	     (if (and (listp arg-expanded)
		      (eql 'apply-scalar-monadic (first arg-expanded)))
		 (let ((innerfn (second arg-expanded)))
		   `(,(if (not (eql 'lambda (first innerfn)))
			  (let ((arg (gensym)))
			    `(lambda (,arg) (funcall ,function (funcall ,innerfn ,arg))))
			  (list (first innerfn)
				(second innerfn)
				`(funcall ,function ,(third innerfn))))
		      ,(third arg-expanded)))
		 (list function (first arguments))))
	   (append (list function (first arguments))
		   (if (second arguments)
		       (list (second arguments)))
		   (if (third arguments)
		       (list (third arguments)))))))

(defmacro scalar-function (function)
  (if (symbolp function)
      `(function ,function)
      function))

(defun process-operator-spec (idiom operator right &optional left)
  ;; (print (list 9999 idiom operator right left))
  (if (member operator (getf (vex::idiom-lexicons idiom) :operators))
      `(funcall ,(gethash operator (getf (vex::idiom-operators idiom)
					 (if (member operator (getf (vex::idiom-lexicons idiom)
								    :lateral-operators))
					     :lateral :pivotal)))
		,right ,@(if left (list left)))))

(defun validate-arg-unitary (value)
  (or (symbolp value)
      (numberp value)
      (and (listp value)
	   (or (not (eql 'vector (first value)))
	       (not (third value))))))

(defun get-function-data (idiom functional-character mode)
  (labels ((find-in-lexicons (character lexicons &optional output)
	     (if (not lexicons)
		 output (find-in-lexicons character (cddr lexicons)
					  (if (member character (second lexicons))
					      (cons (first lexicons)
						    output)
					      output)))))
    (if (characterp functional-character)
	(let ((data (gethash functional-character (getf (vex::idiom-functions idiom) mode))))
	  (if (or (not data)
		  (not (listp data)))
	      data (let ((fn (if (not (eql 'args (first data)))
				 data (first (last data)))))
		     (if (symbolp fn)
			 `(function ,fn)
			 fn))))
	functional-character)))

(defun get-operator-data (idiom functional-character mode)
  (gethash functional-character (getf (vex::idiom-operators idiom) mode)))

(defun enclose-axes (body axis-sets &key (set nil))
  (let ((axes (first axis-sets)))
    (if (not axis-sets)
	body (enclose-axes `(aref-eliding ,body (mapcar (lambda (vector)
							  (if vector (mapcar (lambda (elem) (- elem index-origin))
									     (array-to-list vector))))
							(list ,@axes))
					  ,@(if set (list :set set)))
			   (rest axis-sets)))))

;; (defun enclose-axes (body axis-sets &key (set nil))
;;   (let ((axes (first axis-sets)))
;;     (if (not axis-sets)
;; 	body (enclose-axes `(aref-eliding ,body (mapcar (lambda (vector)
;; 							  (if vector (if (= 1 (length vector))
;; 									 (- (aref vector 0)
;; 									    index-origin)
;; 									 (mapcar (lambda (elem)
;; 										   (- elem index-origin))
;; 										 (array-to-list vector)))))
;; 							(list ,@axes))
;; 					  ,@(if set (list :set set)))
;; 			   (rest axis-sets)))))

(defun output-value (form &optional properties)
  (flet ((apply-props (form form-props)
	   (let ((form-props (if (listp (first form-props))
				 (first form-props)
				 form-props)))
	     ;; wrap output symbols in the (avatom) form so that they are disclosed
	     ;; if part of an APL vector (avector)
	     (funcall (if (not (symbolp form))
			  #'identity (lambda (item) `(avatom ,item)))
		      (if (getf form-props :axes)
			  (enclose-axes form (getf form-props :axes))
			  form)))))
    (let ((properties (reverse properties))
	  (axes (mapcar (lambda (item) (getf item :axes))
			properties)))
      ;;(print (list :aa form axes))
      (if form (if (listp form)
		   (if (not (or (numberp (first form))
				(listp (first form))
				(stringp (first form))
				(and (symbolp (first form))
				     (not (find-symbol (string (first form)))))))
		       (if (= 1 (length properties))
			   (apply-props form (first properties))
			   (mapcar #'apply-props form properties))
		       `(avector ,@(mapcar #'apply-props form properties)))
		   (if (not (numberp form))
		       (apply-props form properties)
		       `(avector ,form)))))))

(defun output-function (form)
  `(lambda (⍵ &optional ⍺)
     (declare (ignorable ⍺))
     (let ((⍵ (disclose ⍵)))
       ,form)))

(defun left-invert-matrix (in-matrix)
  (let* ((input (if (= 2 (rank in-matrix))
		    in-matrix (make-array (list (length in-matrix) 1)
					  :element-type (element-type in-matrix)
					  :initial-contents (loop for i from 0 to (1- (length in-matrix))
							       collect (list (aref in-matrix i))))))
	 (result (array-inner-product
		  (invert-matrix (array-inner-product (aops:permute (reverse (iota (rank input)))
								    input)
						      input
						      (lambda (arg1 arg2) (apply-scalar-dyadic #'* arg1 arg2))
						      #'+))
		  (aops:permute (reverse (iota (rank input)))
				input)
		  (lambda (arg1 arg2) (apply-scalar-dyadic #'* arg1 arg2))
		  #'+)))
    (if (= 1 (rank in-matrix))
	(aref (aops:split result 1) 0)
	result)))

(defun over-operator-template (axes function &key (first-axis nil) (for-vector nil) (for-array nil))
  "Build a function to generate code applying functions over arrays, as for APL's reduce and scan operators."
  `(lambda (omega)
     ,(let ((wrapped-function `(lambda (omega alpha) (funcall ,function omega alpha))))
	`(let ((new-array (copy-array omega)))
	   (disclose (if (vectorp new-array)
			 (funcall ,for-vector ,wrapped-function new-array)
			 (funcall ,for-array ,wrapped-function new-array
				  ,(if axes `(1- (disclose ,(first axes)))
				       (if first-axis 0 `(1- (rank new-array)))))))))))

(defmacro april-function-glyph-processor (type glyph spec)
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
		    :functions (,@(if (or (eq :ambivalent function-type)
					  (eq :monadic function-type))
				      (list :monadic `(scalar-function ,(second spec-body))))
				  ,@(if (or (eq :ambivalent function-type)
					    (eq :dyadic function-type))
					(list :dyadic `(scalar-function ,(first (last spec-body))))))))
	  (t `(,glyph :lexicons (,@(cond ((eq :functions type)
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
							    :lateral-operators :pivotal-operators)))))
		      ,@(cond ((eq :functions type)
			       `(:functions (,@(if (or (eq :ambivalent function-type)
						       (eq :monadic function-type))
						   (list :monadic (first spec-body)))
					       ,@(if (eq :ambivalent function-type)
						     (list :dyadic (second spec-body))
						     (if (eq :dyadic function-type)
							 (list :dyadic (first spec-body))))
					       ,@(if (eq :symbolic function-type)
						     (list :symbolic (first spec-body))))))
			      ((eq :operators type)
			       `(:operators ,(first spec-body)))))))))


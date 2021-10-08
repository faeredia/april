;;; -*- Mode:Lisp; Syntax:ANSI-Common-Lisp; Coding:utf-8; Package:April -*-
;;;; grammar.lisp

(in-package #:april)

"This file contains the specification of April's basic grammar elements, including the basic language components - array, function and operator - and the patterns comprising those elements that make up the language's strucures."

(define-symbol-macro include-closure-meta
    (if (getf (getf properties :special) :closure-meta)
        `(:closure-meta ,(getf (getf properties :special) :closure-meta))))

(define-symbol-macro include-closure-meta-last
    (if (getf (getf (first (last preceding-properties)) :special) :closure-meta)
        `(:closure-meta ,(getf (getf (first (last preceding-properties)) :special)
                               :closure-meta))))

(defun process-value (this-item properties process idiom space)
  "Process a value token."
  (cond ((and (listp this-item)
              (not (member (first this-item) '(:fn :op :st :pt :axes))))
         ;; if the item is a closure, evaluate it and return the result
         (let ((sub-props (list :special
                                (list :closure-meta (getf (getf properties :special) :closure-meta)))))
           (multiple-value-bind (output out-properties)
               (funcall process this-item sub-props)
             (if (eq :array (first (getf out-properties :type)))
                 (progn (if (not (member :enclosed (getf out-properties :type)))
                            (setf (getf out-properties :type)
                                  (cons (first (getf out-properties :type))
                                        (cons :enclosed (rest (getf out-properties :type))))))
                        (values output out-properties))
                 (values nil nil)))))
        ((and (listp this-item)
              (eq :pt (first this-item)))
         (let ((nspath (format-nspath (rest this-item))))
           (if (or (not nspath) (not (fboundp (intern nspath space)))
                   (getf properties :symbol-overriding))
               (values (cons 'nspath (cons `(inws ,(second this-item))
                                           (loop :for i :in (cddr this-item)
                                                 :collect (if (symbolp i)
                                                              i (if (and (listp i)
                                                                         (eq :axes (first i)))
                                                                    (list (mapcar (lambda (item)
                                                                                    (funcall process item))
                                                                                  (rest i))))))))
                       '(:type :symbol))
               (values nil nil))))
        ;; process the empty vector expressed by the [⍬ zilde] character
        ((eq :empty-array this-item)
         (values (make-array 0) '(:type (:array :empty))))
        ;; process numerical values
        ((and (numberp this-item)
              (or (not (getf properties :type))
                  (eq :number (first (getf properties :type)))))
         (values this-item '(:type (:array :number))))
        ;; process string values
        ((and (stringp this-item)
              (or (not (getf properties :type))
                  (eq :string (first (getf properties :type)))))
         (values this-item '(:type (:array :string))))
        ;; process scalar character values
        ((and (characterp this-item)
              (or (not (getf properties :type))
                  (eq :character (first (getf properties :type)))))
         (values this-item '(:type (:array :character))))
        ;; process symbol-referenced values
        ((and (symbolp this-item)
              (or (member this-item '(⍵ ⍺ ⍹ ⍶) :test #'eql)
                  (getf properties :symbol-overriding)
                  (not (is-workspace-function this-item)))
              (or (getf properties :symbol-overriding)
                  (not (member this-item
                               (append '(⍺⍺ ⍵⍵)
                                       (of-meta-hierarchy (rest (getf (getf properties :special) :closure-meta))
                                                          :fn-syms)
                                       (of-meta-hierarchy (rest (getf (getf properties :special) :closure-meta))
                                                          :lop-syms)
                                       (of-meta-hierarchy (rest (getf (getf properties :special) :closure-meta))
                                                          :pop-syms)))))
              ;; make sure the symbol doesn't reference a lexically-defined function
              (or (not (is-workspace-operator this-item))
                  (getf properties :symbol-overriding))
              (not (member (intern (string-upcase this-item) *package-name-string*)
                           (rest (assoc :function (idiom-symbols idiom)))))
              (not (member this-item '(⍺⍺ ⍵⍵ ∇ ∇∇) :test #'eql))
              (or (not (getf properties :type))
                  (eq :symbol (first (getf properties :type)))))
         (values (if (not (member (intern (string-upcase this-item) *package-name-string*)
                                  (rest (assoc :function (idiom-symbols idiom)))))
                     this-item (intern (string-upcase this-item)))
                 '(:type (:symbol))))
        (t (values nil nil))))

(defun process-function (this-item properties process idiom space)
  "Process a function token."
  (if (listp this-item)
      ;; process a function specification starting with :fn
      (if (or (eq :fn (first this-item))
              ;; if marked as an operator, check whether the character is one entered as both
              ;; a function and an operator; such functions must be dyadic
              (and (eq :op (first this-item))
                   (or (of-lexicons idiom (third this-item) :functions-dyadic)
                       (of-lexicons idiom (third this-item) :functions-symbolic))))
          (let ((fn (first (last this-item)))
                (obligate-dyadic (and (eq :op (first this-item))
                                      (of-lexicons idiom (third this-item) :functions-dyadic)))
                (overloaded-operator (and (eq :op (first this-item))
                                          (or (of-lexicons idiom (third this-item) :functions-dyadic)
                                              (of-lexicons idiom (third this-item) :functions-symbolic)))))
            (cond ((and (characterp fn)
                        (or (not (getf properties :glyph))
                            (and (char= fn (aref (string (getf properties :glyph)) 0)))))
                   (values fn (list :type (append '(:function :glyph)
                                                  (if overloaded-operator '(:overloaded-operator))
                                                  (if (of-lexicons idiom (third this-item) :functions-symbolic)
                                                      '(:symbolic-function))))))
                  ((and (listp fn)
                        (not (getf properties :glyph)))
                   (let* ((polyadic-args (if (and (listp (first (last (first fn))))
                                                  (eq :axes (caar (last (first fn)))))
                                             (mapcar #'caar (cdar (last (first fn))))))
                          (fn (if (not polyadic-args)
                                  fn (cons (butlast (first fn) 1)
                                           (rest fn))))
                          ;; (initial-expr (first (last (first (last this-item)))))
                          (arg-symbols (intersection '(⍺ ⍵ ⍶ ⍹ ⍺⍺ ⍵⍵ ∇∇) (getf (cdadr this-item) :arg-syms)))
                          (this-closure-meta (second this-item))
                          (is-inline-operator (intersection arg-symbols '(⍶ ⍹ ⍺⍺ ⍵⍵ ∇∇))))
                     (if (= 2 (length (intersection arg-symbols '(⍶ ⍺⍺))))
                         (error "A defined operator may not include both [⍶ left value] and~a"
                                " [⍺⍺ left function] operands."))
                     (if (= 2 (length (intersection arg-symbols '(⍹ ⍵⍵))))
                         (error "A defined operator may not include both [⍹ right value] and~⍺"
                                " [⍵⍵ right function] operands."))
                     ;; if this is an inline operator, pass just that keyword back
                     (if is-inline-operator :is-inline-operator
                         (let ((sub-props (list :special (list :closure-meta this-closure-meta))))
                           (setf (getf (rest this-closure-meta) :var-syms)
                                 (append polyadic-args (getf (rest this-closure-meta) :var-syms)))
                           (values (output-function (mapcar (lambda (f) (funcall process f sub-props)) fn)
                                                    polyadic-args (rest this-closure-meta))
                                   (list :type '(:function :closure)
                                         :obligate-dyadic obligate-dyadic))))))
                  (t (values nil nil))))
          ;; process sub-list in case it is a functional expression like (+∘*),
          ;; but don't do this if looking for a specific functional glyph
          (if (not (getf properties :glyph))
              (if (eq :pt (first this-item))
                  (let* ((nspath (format-nspath (rest this-item)))
                         (nspath-sym (intern nspath space)))
                    (if (fboundp nspath-sym)
                        (values `(inws ,(intern nspath))
                                '(:type (:function :referenced :by-path)))
                        (values nil nil)))
                  (let ((sub-props (list :special
                                         (list :closure-meta (getf (getf properties :special) :closure-meta)
                                               :from-outside-functional-expression t))))
                    (multiple-value-bind (output out-properties)
                        (funcall process this-item sub-props)
                      (if (eq :function (first (getf out-properties :type)))
                          (progn (if (not (member :enclosed (getf out-properties :type)))
                                     (setf (getf out-properties :type)
                                           (cons (first (getf out-properties :type))
                                                 (cons :enclosed (rest (getf out-properties :type))))))
                                 (values output out-properties))
                          (values nil nil)))))
              (values nil nil)))
      (if (and (symbolp this-item)
               (not (getf properties :glyph)))
          (cond ((is-workspace-function this-item)
                 ;; process workspace-aliased lexical functions, as when f←+ has been set
                 (values this-item (list :type '(:function :referenced))))
                ((eql this-item '∇)
                 (values this-item (list :type '(:function :self-reference))))
                ((member this-item '(⍵⍵ ⍺⍺))
                 (values this-item (list :type '(:function :operand-function-reference))))
                ((member this-item (of-meta-hierarchy (rest (getf (getf properties :special) :closure-meta))
                                                      :fn-syms))
                 (values (if (eql '⍺ this-item)
                             this-item (list 'inws this-item))
                         (list :type '(:function :lexical-function))))
                ((member (intern (string-upcase this-item) *package-name-string*)
                         (rest (assoc :function (idiom-symbols idiom))))
                 (values (let ((idiom-function-object (getf (rest (assoc :function (idiom-symbols idiom)))
                                                            (intern (string-upcase this-item)
                                                                    *package-name-string*))))
                           (if (listp idiom-function-object)
                               idiom-function-object (list 'function idiom-function-object)))
                         (list :type '(:function :referenced))))
                (t (values nil nil)))
          (values nil nil))))

(defun process-operator (this-item properties process idiom space)
  "Process an operator token."
  (declare (ignore idiom))
  (if (listp this-item)
      (if (and (eq :op (first this-item))
               (not (listp (first (last this-item))))
               (or (not (getf properties :glyph))
                   (not (characterp (first (last this-item))))
                   (char= (character (getf properties :glyph))
                          (first (last this-item)))))
          ;; process an operator token, allowing specification of the valence,
          ;; either :lateral or :pivotal
          (destructuring-bind (op-type op-symbol)
              (rest this-item)
            (let ((valid-by-valence (or (not (getf properties :valence))
                                        (eq op-type (getf properties :valence)))))
              (if (and valid-by-valence (eql '∇∇ op-symbol))
                  (values :operator-self-reference
                          (list :type (list :operator op-type)))
                  (cond ((and valid-by-valence (getf properties :glyph))
                         (if (char= op-symbol (aref (string (getf properties :glyph)) 0))
                             (values op-symbol (list :type (list :operator op-type)))
                             (values nil nil)))
                        (valid-by-valence (values op-symbol (list :type (list :operator op-type))))
                        (t (values nil nil))))))
          (if (and (eql :op (first this-item))
                   (listp (first (last this-item)))
                   (not (getf properties :glyph)))
              (let* ((fn (first (last this-item)))
                     (arg-symbols (intersection '(⍺ ⍵ ⍶ ⍹ ⍺⍺ ⍵⍵ ∇∇) (getf (cdadr this-item) :arg-syms)))
                     (this-closure-meta (second this-item))
                     (is-inline (intersection arg-symbols '(⍶ ⍹ ⍺⍺ ⍵⍵)))
                     (is-dyadic (member '⍺ arg-symbols))
                     (is-pivotal (intersection arg-symbols '(⍹ ⍵⍵)))
                     (valence (getf properties :valence)))
                (if (= 2 (length (intersection arg-symbols '(⍶ ⍺⍺))))
                    (error "A defined operator may not include both [⍶ left value] and~a"
                           " [⍺⍺ left function] operands."))
                (if (= 2 (length (intersection arg-symbols '(⍹ ⍵⍵))))
                    (error "A defined operator may not include both [⍹ right value] and~⍺"
                           " [⍵⍵ right function] operands."))
                (if is-inline (if (or (not valence)
                                      (and is-pivotal (eq :pivotal valence))
                                      (and (not is-pivotal) (eq :lateral valence)))
                                  (let ((sub-props (list :special (list :closure-meta this-closure-meta))))
                                     (values (output-function
                                             (mapcar (lambda (f) (funcall process f sub-props)) fn)
                                             nil (rest this-closure-meta))
                                            (list :type (remove
                                                         nil (list :operator :closure
                                                                   (if is-pivotal :pivotal :lateral)
                                                                   (if is-dyadic :dyadic :monadic)
                                                                   ;; indicate the types of the operands for use
                                                                   ;; in the function composer pattern below
                                                                   (if (member '⍶ arg-symbols)
                                                                       :left-operand-value
                                                                       (if (member '⍺⍺ arg-symbols)
                                                                           :left-operand-function))
                                                                   (if (member '⍹ arg-symbols)
                                                                       :right-operand-value
                                                                       (if (member '⍵⍵ arg-symbols)
                                                                           :right-operand-function))))))))
                    (values nil nil)))
              (values nil nil)))
      (if (symbolp this-item)
          ;; if the operator is represented by a symbol, it is a user-defined operator
          ;; and the appropriate variable name should be verified in the workspace
          (let* ((symbol-string (string this-item))
                 ;; (type-to-find (getf properties :valence))
                 (closure-meta (rest (getf (getf properties :special) :closure-meta)))
                 (lop-string (if (eq :lateral (getf properties :valence))
                                 symbol-string))
                 (pop-string (if (eq :pivotal (getf properties :valence))
                                 symbol-string))
                 (bound-op (if (and lop-string
                                    (or (and (fboundp (intern lop-string space))
                                             (boundp (intern lop-string space))
                                             (eq :lateral (getf (rest (symbol-value (intern lop-string space)))
                                                                :valence)))
                                        (member this-item (of-meta-hierarchy closure-meta :lop-syms))))
                               (intern lop-string)
                               (if (and pop-string
                                        (or (and (fboundp (intern pop-string space))
                                                 (boundp (intern pop-string space))
                                                 (eq :pivotal
                                                     (getf (rest (symbol-value (intern pop-string space)))
                                                           :valence)))
                                            (member this-item (of-meta-hierarchy closure-meta :pop-syms))))
                                   (intern pop-string)))))
            (if bound-op
                (values bound-op (list :type (list :operator (or (getf properties :valence)
                                                                 (if (fboundp (intern pop-string space))
                                                                     :pivotal :lateral)))))
                (values nil nil)))
          (values nil nil))))

(defun process-statement (this-item properties process idiom space)
  "Process a statement token, allowing specification of the valence, either :lateral or :pivotal."
  (declare (ignore idiom process space))
  (if (and (listp this-item) (eq :st (first this-item)))
      (destructuring-bind (st-type st-symbol) (rest this-item)
        (let ((valid-by-valence (or (not (getf properties :valence))
                                    (eq st-type (getf properties :valence)))))
          (cond ((and valid-by-valence (getf properties :glyph))
                 (if (char= st-symbol (aref (string (getf properties :glyph)) 0))
                     (values st-symbol (list :type (list :statement st-type)))
                     (values nil nil)))
                (valid-by-valence (values st-symbol (list :type (list :statement st-type))))
                (t (values nil nil)))))
      (values nil nil)))

;; the value-matcher is the most idiosyncratic of patterns, and thus it is
;; specified explicitly without the use of the (composer-pattern) macro
(defun composer-pattern-value (tokens space idiom process &optional precedent properties preceding-properties)
  "Match an array like 1 2 3, marking the beginning of an array expression, or a functional expression if the array is an operand to a pivotal operator."
  (declare (ignorable precedent properties preceding-properties))
  (symbol-macrolet ((item (first items)) (rest-items (rest items)))
    (let ((axes) (value-elements) (value-props) (stopped) (items tokens)
          (special-props (list :special nil)))
      (if (member :top-level (getf (first (last preceding-properties)) :special))
          (setf (getf (second special-props) :top-level) t))
      (setf (getf (second special-props) :closure-meta)
            (getf (getf properties :special) :closure-meta))
      (labels ((axes-enclose (item axes)
                 (if (not axes) item (enclose-axes item axes))))
        (if (and (listp item) (eql :axes (first item)))
            (setq axes (list (loop :for axis :in (rest item)
                                :collect (funcall process axis special-props)))
                  items rest-items))
        (if (and axes (not items))
            (error "Encountered axes with no function, operator or value to the left."))
        (loop :while (not stopped) ;; :for index :from 0
              :do (or (if (and (listp item) (eq :axes (first item)))
                          ;; if axes are encountered, process the axes and the preceding
                          ;; value as a new value
                          (multiple-value-bind (output properties remaining)
                              (funcall process items special-props)
                            (if (eq :array (first (getf properties :type)))
                                (setq items remaining
                                      value-elements (cons output value-elements)
                                      value-props (cons properties value-props)
                                      stopped t))))
                      (if (and (listp item) (not (member (first item) '(:op :fn :st :pt :axes))))
                          ;; if a closure is encountered, recurse to process it
                          (multiple-value-bind (output properties)
                              (funcall process item special-props)
                            (if (eq :array (first (getf properties :type)))
                                (setq items rest-items
                                      value-elements (cons output value-elements)
                                      value-props (cons properties value-props)))))
                      (multiple-value-bind (value-out value-properties)
                          (process-value item properties process idiom space)
                        (if value-out (setq items rest-items
                                            value-elements (cons value-out value-elements)
                                            value-props (cons value-properties value-props))))
                      (setq stopped t)))
        (if value-elements
            (values (axes-enclose (output-value space (if (< 1 (length value-elements))
                                                          value-elements (first value-elements))
                                                value-props
                                                (of-meta-hierarchy (rest (getf (getf properties :special)
                                                                               :closure-meta))
                                                                   :var-syms))
                                  axes)
                    '(:type (:array :explicit))
                    items)
            (values nil nil tokens))))))

(vex::composer-pattern-template
 (composer-pattern assign-axes assign-element assign-subprocessed)
 tokens space idiom process precedent properties preceding-properties special-props items item rest-items)

(composer-pattern composer-pattern-function (axes function-form function-props prior-items is-inline-operator)
    ;; match a function like × or {⍵+10}, marking the beginning of a functional expression
    ((assign-axes axes process)
     (setq prior-items items)
     ;; (print (list :it items))
     (assign-element function-form function-props process-function (first (last preceding-properties)))
     (if (and (not function-form) (listp (first items))
              (eql :op (caar items)) (listp (first (last (first items)))))
         (progn (setq items prior-items)
                ;; handle inline operators as with ÷{⍺⍺ ⍵}4, unless the operator is being assigned
                ;; as with op←{⍺⍺ ⍵}
                (if (and (assign-element function-form function-props process-operator)
                         (not (and (listp (first items)) (eq :fn (caar items))
                                   (char= #\← (cadar items)))))
                    (setq is-inline-operator t)))))
  (let ((is-function (or (and (not is-inline-operator)
                              (not (member :overloaded-operator (getf function-props :type))))
                         (and (listp function-form)
                              (eql 'nspath (first function-form)))
                         (let* ((sub-properties
                                 ;; create special properties for next level down
                                  `(:special (,@include-closure-meta-last
                                              :omit ,(intersection '(:train-composition)
                                                                   (getf (getf properties :special) :omit)))))
                                (next (if items (multiple-value-list (funcall process items sub-properties)))))
                           (and (not (member :function (getf (second next) :type)))
                                (not (and (listp (first next))
                                          (eql 'inws (caar next))
                                          (symbolp (cadar next))
                                          (member (cadar next)
                                                  (of-meta-hierarchy (rest (getf (getf properties :special)
                                                                                 :closure-meta))
                                                                     :fn-syms))))
                                (not (third next)))))))
    (if (and (member :left-operand-value (getf function-props :type))
             (not (and (listp (first items)) (eq :fn (caar items))
                       (char= #\← (cadar items)))))
        ;; disqualify inline operators whose left operand is a value, as for { ↑⍵{(⍺|⍶+⍵)-⍵}/2*⍺-0 1 },
        ;; unless the operator is being assigned a name
        (values nil nil prior-items)
        (if (and function-form is-function)
            (values (if (or (not axes) (of-lexicons idiom function-form :functions))
                        ;; if axes are present, this is an n-argument function
                        (if (not (and (symbolp function-form) (is-workspace-function function-form)))
                            function-form `(function (inws ,function-form)))
                        (let ((call-form (if (listp function-form)
                                             function-form `(function ,(insym function-form)))))
                          `(a-call ,call-form ,@(first axes))))
                    (list :type (if (member :operator (getf function-props :type))
                                    (list :operator :inline-operator
                                          (if (member :pivotal (getf function-props :type))
                                              :pivotal :lateral))
                                    '(:function :inline-function))
                          :axes (or axes (getf function-props :axes)))
                    items)))))

(composer-pattern composer-pattern-operator-alias (operator-axes operator-form operator-props
                                                                 asop asop-props symbol symbol-props)
    ;; match a lexical operator alias like key←⌸
    ((let ((sub-props (list :special (list :closure-meta (getf (getf properties :special) :closure-meta)))))
       (assign-axes operator-axes (lambda (i) (funcall process i sub-props))))
     (assign-element operator-form operator-props process-operator)
     (if operator-form (assign-element asop asop-props process-function '(:glyph ←)))
     (if asop (assign-element symbol symbol-props process-value '(:symbol-overriding t))))
  (let* ((type (getf operator-props :type))
         (operator-type (second type))
         (operator (and (member :operator type) operator-form))
         (at-top-level (member :top-level (getf (first (last preceding-properties)) :special))))
    (if (and symbol operator-form (member operator-type '(:lateral :pivotal))
             (of-lexicons idiom operator (intern (format nil "OPERATORS-~a" operator-type)
                                                 "KEYWORD")))
        (values `(setf ,(if at-top-level `(symbol-function (quote (inws ,symbol)))
                            `(inws ,symbol))
                       (lambda ,(if (eq :lateral operator-type)
                                    (if operator-axes '(operand) '(operand &optional axes))
                                    (if (eq :pivotal operator-type) '(left right)))
                         ,@(if (and (not operator-axes)
                                    (eq :lateral operator-type))
                               '((declare (ignorable axes)))
                               (if (eq :pivotal operator-type) '((declare (ignorable right left)))))
                         ,(if operator-axes
                              (apply (symbol-function (intern (format nil "APRIL-LEX-OP-~a" operator-form)
                                                              *package-name-string*))
                                     (if (eq :lateral operator-type)
                                         (list 'operand (if (listp (first operator-axes))
                                                            (cons 'list (first operator-axes))
                                                            `(list ,(first operator-axes))))
                                         (list 'right 'left)))
                              (apply (symbol-function (intern (format nil "APRIL-LEX-OP-~a" operator-form)
                                                              *package-name-string*))
                                     (if (eq :lateral operator-type)
                                         '(operand axes) '(right left))))))
                '(:type (:operator :aliased))
                items))))

(labels ((verify-lateral-operator-symbol (symbol space closure-meta)
           (if (symbolp symbol) (let ((symbol (intern (string symbol))))
                                  (if (or (member symbol (of-meta-hierarchy closure-meta :lop-syms))
                                          (and (fboundp (intern (string symbol) space))
                                               (boundp (intern (string symbol) space))
                                               (eq :lateral (getf (rest (symbol-value (intern (string symbol)
                                                                                              space)))
                                                                  :valence))))
                                      symbol)))))
  (composer-pattern composer-pattern-lateral-composition
      (operator-axes operator-form operator-props operand-axes operand-form
                     operand-props symbol-plain symbol-referenced env-lops)
      ;; match a lateral function composition like +/, marking the beginning of a functional expression
      ((assign-axes operator-axes process)
       (setq symbol-plain item
             symbol-referenced (verify-lateral-operator-symbol
                                symbol-plain space (rest (getf (getf properties :special) :closure-meta))))
       (assign-element operator-form operator-props process-operator
                       `(:valence :lateral :special (,@include-closure-meta)))
       (if operator-form (progn (assign-axes operand-axes process)
                                (setq env-lops
                                      (of-meta-hierarchy (rest (getf (getf properties :special) :closure-meta))
                                                         :lop-syms))
                                (assign-subprocessed
                                 operand-form operand-props
                                 `(:special (:omit (:value-assignment :function-assignment
                                                                      :operation :operator-assignment
                                                                      :train-composition)
                                                   ,@include-closure-meta-last))))))
    (if symbol-referenced
        ;; call the operator constructor on the output of the operand constructor which integrates axes
        (values `(a-comp :op ,(list (if (and (fboundp (intern (string symbol-referenced) space))
                                             (not (member symbol-plain env-lops)))
                                        'inwsd 'inws)
                                    symbol-referenced)
                         ,(if (not (characterp operand-form))
                              operand-form (build-call-form operand-form :dyadic operand-axes))
                         ,@(if operator-axes `((list ,@(first operator-axes)))))
                '(:type (:function :operator-composed :lateral))
                items)
        (let ((operator (and (member :operator (getf operator-props :type))
                             (member :lateral (getf operator-props :type))
                             operator-form)))
          (if operator
              (if (eq :operator-self-reference operator-form)
                  (values `(a-comp :op ∇oself ,operand-form)
                          '(:type (:function :operator-composed :lateral))
                          items)
                  (values (if (listp operator-form)
                              `(a-comp :op ,operator-form
                                       ,(if (not (characterp operand-form))
                                            operand-form (build-call-form operand-form :dyadic operand-axes)))
                              (let ((operand (if (eql '∇ operand-form)
                                                 '#'∇self
                                                 (if (and (characterp operand-form)
                                                          (of-lexicons idiom operand-form :functions))
                                                     (build-call-form operand-form :dyadic operand-axes)
                                                     operand-form))))
                                (cons 'a-comp
                                      (cons (intern (string-upcase operator) *package-name-string*)
                                            (funcall (symbol-function
                                                      (intern (format nil "APRIL-LEX-OP-~a" operator-form)
                                                              *package-name-string*))
                                                     operand (if (listp (first operator-axes))
                                                                 (cons 'list (first operator-axes))
                                                                 (list (first operator-axes))))))))
                          '(:type (:function :operator-composed :lateral))
                          items)))))))

(composer-pattern composer-pattern-unitary-statement (statement-axes statement-form statement-props)
    ;; match a unitary operator like $
    ((let ((sub-props (list :special (list :closure-meta (getf (getf properties :special) :closure-meta)))))
       (assign-axes statement-axes (lambda (i) (funcall process i sub-props))))
     (assign-element statement-form statement-props process-statement '(:valence :unitary)))
  (let ((statement (and (member :statement (getf statement-props :type))
                        (member :unitary (getf statement-props :type))
                        statement-form)))
    (if (of-lexicons idiom statement :statements)
        (values (funcall (symbol-function (intern (format nil "APRIL-LEX-ST-~a" statement)
                                                  *package-name-string*))
                         (first statement-axes))
                '(:type (:array :evaluated))
                items))))

(defvar *composer-opening-patterns*)

(setq *composer-opening-patterns*
      '((:name :value :function composer-pattern-value)
        (:name :function :function composer-pattern-function)
        (:name :operator-alias :function composer-pattern-operator-alias)
        (:name :lateral-composition :function composer-pattern-lateral-composition)
        (:name :unitary-operator :function composer-pattern-unitary-statement)))

(composer-pattern value-assignment-by-function-result
    (asop asop-props fn-element fnel-specs function-axes symbol symbol-props symbol-axes)
    ;; "Match the assignment of a function result to a value, like a+←5."
    ;; note that this is the method for assigning values to a variable outside the local scope of a function
    ((assign-element asop asop-props process-function '(:glyph ←))
     (if asop (assign-axes function-axes process))
     (if asop (assign-subprocessed fn-element fnel-specs
                                   `(:special (:omit (:value-assignment :function-assignment)
                                                     ,@include-closure-meta-last))))
     (if fn-element (assign-axes symbol-axes process))
     (if fn-element (assign-element symbol symbol-props process-value '(:symbol-overriding t))))
  (if (and fn-element symbol)
      (let ((assigned (gensym))
            (qsym (if (listp symbol)
                      symbol
                      (if (member symbol
                                  (of-meta-hierarchy (rest (getf (getf properties :special) :closure-meta))
                                                     :var-syms))
                          `(inws ,symbol) (intern (string symbol) space))))
            ;; find the value either among the lexical variables or the dynamic variables
            (fn-content (if (not (and (characterp fn-element)
                                      (of-lexicons idiom fn-element :functions)))
                            fn-element (build-call-form fn-element))))
        (values (if (not symbol-axes)
                    (if (listp symbol) ;; handle namespace paths
                        `(a-set ,symbol ,precedent :by (lambda (item item2)
                                                         (a-call ,fn-content item item2)))
                        `(let ((,assigned (a-call ,fn-content ,precedent ,qsym
                                                  ,@(if function-axes `((list ,@(first function-axes)))))))
                           (if (boundp (quote ,(intern (string symbol) space)))
                               (setf (symbol-value (quote ,(intern (string symbol) space))) ,assigned))
                           (setf (inws ,symbol) ,assigned)))
                    `(a-set (inws ,symbol) ,precedent
                            :axes ,symbol-axes :by (lambda (item item2)
                                                     (a-call ,fn-content item item2))))
                '(:type (:array :assigned :by-result-assignment-operator))
                items))))

(composer-pattern value-assignment-by-selection
    (asop asop-props selection-axes val-sym selection-form sform-specs)
    ;; match a selective value assignment like (3↑x)←5
    ((assign-element asop asop-props process-function '(:glyph ←))
     (if (and asop (and (listp (first items))
                        (not (member (caar items) '(:fn :op :st :pt :axes)))))
         (let ((items (first items)))
           (assign-axes selection-axes process)
           (if (symbolp item) (setq val-sym item))
           (assign-subprocessed selection-form sform-specs
                                '(:special (:omit (:value-assignment :function-assignment))))))
     (if selection-form (setf items (rest items))))
  (if (and selection-form (listp selection-form) (eql 'a-call (first selection-form)))
      (let ((val-sym-form (list (if (boundp (intern (string val-sym) space))
                                    'inwsd 'inws)
                                val-sym))
            (prime-function (second selection-form))
            (item (gensym)))
        (labels ((set-assn-sym (form)
                   (if (and (listp (third form))
                            (member (first (third form)) '(inws inwsd)))
                       (setf (third form) item)
                       (if (and (listp (third form))
                                (eql 'a-call (first (third form))))
                           (set-assn-sym (third form))))))
          (set-assn-sym selection-form)
          (values `(progn (a-set ,val-sym-form
                                 (assign-by-selection
                                  ,(if (or (symbolp prime-function)
                                           (eql 'apl-fn (first prime-function)))
                                       ;; TODO: make this work with an aliased ¨ operator
                                       prime-function (if (eql 'a-comp (first prime-function))
                                                          (if (eql '|¨| (second prime-function))
                                                              (fourth prime-function)
                                                              (error "Invalid operator-composed expression ~a"
                                                                     "used for selective assignment."))))
                                  (lambda (,item) ,selection-form)
                                  ,precedent ,val-sym-form :axes
                                  (mapcar (lambda (array) (if array (apply-scalar #'- array index-origin)))
                                          (list ,@(first selection-axes)))))
                          ,precedent)
                  '(:type (:array :assigned))
                  items)))))

(composer-pattern value-assignment-standard
    (asop asop-props axes symbol symbols symbols-props symbols-list preceding-type)
    ;; match a value assignment like a←1 2 3, part of an array expression
    ((setq preceding-type (getf (first preceding-properties) :type))
     (if (and (eq :array (first preceding-type))
              (not (member :value-assignment (getf special-props :omit))))
         (assign-element asop asop-props process-function '(:glyph ←)))
     (if asop (labels ((get-symbol-list (list &optional inner)
                         (let ((valid t))
                           (if (listp list)
                               ;; build list of symbols to be assigned values
                               ;; (multiple for stranded/nested assignment)
                               (let ((out-list (loop :while valid :for i
                                                  :in (if (and (not inner)
                                                               (not (eql 'avector (first list))))
                                                          list (rest list))
                                                  :collect (setq valid
                                                                 (if (symbolp i)
                                                                     (progn (if (not (member i symbols-list))
                                                                                (setq symbols-list
                                                                                      (cons i symbols-list)))
                                                                            i)
                                                                     (if (and (listp i)
                                                                              (member (first i)
                                                                                      '(inws inwsd)))
                                                                         (progn (setq symbols-list
                                                                                      (cons (second i)
                                                                                            symbols-list))
                                                                                i)
                                                                         (get-symbol-list i t)))))))
                                 (if valid out-list))))))
                (assign-axes axes process)
                (let ((symbols-present t))
                  ;; collect each symbol to the left of ←, keeping them in (inws) forms if needed
                  (loop :while symbols-present :for sx :from 0
                     :do (multiple-value-bind (symbol-out symbol-props)
                             (process-value item `(,@(if (= 0 sx) '(:symbol-overriding t))
                                                   :special ,(getf (first (last preceding-properties))
                                                                     :special))
                                            process idiom space)
                           (if (listp symbol-out)
                               (if (not (eql 'nspath (first symbol-out)))
                                   (setq symbol-out (get-symbol-list symbol-out)))
                               (if (symbolp symbol-out)
                                   (progn (if (not (member symbol-out symbols-list))
                                              (setq symbols-list (cons symbol-out symbols-list)))
                                          (if (not (member symbol-out *idiom-native-symbols*))
                                              (setq symbol-out (list 'inws symbol-out))))))
                           (if (and symbol-out (or (symbolp symbol-out)
                                                   (and symbol-out (listp symbol-out))))
                               (setq items rest-items
                                     symbols (cons symbol-out symbols)
                                     symbols-props (cons symbol-props symbols-props))
                               (setq symbols-present nil))))
                  (if (and (= 1 (length symbols))
                           (listp (first symbols)))
                      (setq symbols (first symbols)))
                  (setq symbol (if (symbolp (first symbols))
                                   (if (member (first symbols) '(inws inwsd nspath))
                                       symbols (first symbols))
                                   (if (listp (first symbols))
                                       (caar symbols))))))))
  (if symbols
      ;; ensure symbol(s) are not bound to function values in the workspace, and
      ;; define them as dynamic variables if they're unbound there;
      ;; remove symbols from (inws) unless they're bare and thus idiom-native
      (values
       (progn (cond ((eql 'to-output symbol)
                     ;; a special case to handle ⎕← quad output
                     `(a-out ,precedent :print-precision print-precision
                                        :print-to output-stream :print-assignment t :with-newline t))
                    ((eql 'output-stream symbol)
                     ;; a special case to handle ⎕ost← setting the output stream; the provided string
                     ;; is interned in the current working package
                     (if (stringp precedent)
                         ;; setq is used instead of a-set because output-stream is a lexical variable
                         `(setq output-stream ,(intern precedent (package-name *package*)))
                         (if (listp precedent)
                             (destructuring-bind (vector-symbol package-string symbol-string) precedent
                               (if (and (eql 'avector vector-symbol)
                                        (stringp package-string)
                                        (stringp symbol-string))
                                   ;; if the argument is a vector of two strings like ('APRIL' 'OUT-STR'),
                                   ;; intern the symbol like (intern "OUT-STR" "APRIL")
                                   `(setq output-stream ,(intern symbol-string package-string))
                                   (error "Invalid assignment to ⎕OST.")))
                             (error "Invalid assignment to ⎕OST."))))
                    (t (loop :for symbol :in symbols-list
                             :do (if (is-workspace-function symbol)
                                     (fmakunbound (intern (string symbol) space)))
                                 (if (and (not (boundp (intern (string symbol) space)))
                                          (member :top-level (getf (first (last preceding-properties)) :special)))
                                     ;; only bind dynamic variables in the workspace if the compiler
                                     ;; is at the top level; i.e. not within a { function }, where
                                     ;; bound variables are lexical
                                     (progn (proclaim (list 'special (intern (string symbol) space)))
                                            (set (intern (string symbol) space) nil))))
                       (let ((osymbol (if (symbolp symbol)
                                          symbol (if (and (listp symbol)
                                                          (member (first symbol) '(inws inwsd)))
                                                     (second symbol)))))
                         (if (getf (getf (first (last preceding-properties)) :special)
                                   :closure-meta)
                             (setf (getf (rest (getf (getf (first (last preceding-properties))
                                                           :special)
                                                     :closure-meta))
                                         :fn-syms)
                                   (remove osymbol (getf (rest (getf (getf (first (last preceding-properties))
                                                                           :special)
                                                                     :closure-meta))
                                                         :fn-syms))))
                         (if (and (getf (getf (first (last preceding-properties)) :special)
                                        :closure-meta)
                                  (not (member osymbol
                                               (getf (rest (getf (getf (first
                                                                        (last preceding-properties))
                                                                       :special)
                                                                 :closure-meta))
                                                     :var-syms))))
                             (push osymbol (getf (rest (getf (getf (first (last preceding-properties))
                                                                   :special)
                                                             :closure-meta))
                                                 :var-syms)))
                         ;; enclose the symbol in (inws) so the (with-april-workspace) macro
                         ;; will correctly intern it, unless it's one of the system variables
                         `(a-set ,(if (not (and (listp symbols)
                                                (not (or (eql 'inws (first symbols))
                                                         (eql 'inwsd (first symbols))))))
                                      symbols (if (= 1 (length symbols))
                                                  (first symbols)
                                                  (if (eql 'nspath (first symbols))
                                                      symbols (cons 'avector symbols))))
                                 ,precedent ,@(if axes (list :axes axes)))))))
       '(:type (:array :assigned))
       items)))

(composer-pattern function-assignment (asop asop-props symbol symbol-props preceding-type)
    ;; "Match a function assignment like f←{⍵×2}, part of a functional expression."
    ((setq preceding-type (getf (first preceding-properties) :type))
     (if (eq :function (first preceding-type))
         (assign-element asop asop-props process-function '(:glyph ←)))
     (if asop (assign-element symbol symbol-props process-value '(:symbol-overriding t))))
  (labels ((follow-path (item path)
             (if (not path)
                 item (follow-path `(getf ,item ,(intern (string (first path)) "KEYWORD"))
                                   (rest path)))))
    (if asop (values (let ((at-top-level (member :top-level (getf (first (last preceding-properties))
                                                                  :special))))
                       ;; dummy function initialization is carried out here as well as in the idiom's
                       ;; :lexer-postprocess method in order to catch assignments of composed functions like
                       ;; g←(3∘×); these are not recognized by :lexer-postprocess since it should not be aware
                       ;; of operator composition conventions in the code it receives
                       (if (and (symbolp symbol)
                                (member :top-level (getf (first (last preceding-properties)) :special)))
                           (progn (if (is-workspace-value symbol)
                                      (makunbound (intern (string symbol) space)))
                                  (if (not (fboundp (intern (string symbol) space)))
                                      (setf (symbol-function (intern (string symbol) space))
                                            #'dummy-nargument-function))))
                       (if (and (listp precedent) (symbolp symbol)
                                (member (first precedent) '(lambda a-comp))
                                (member symbol (getf (rest (getf (getf (first (last preceding-properties))
                                                                       :special)
                                                                 :closure-meta))
                                                     :var-syms)))
                           (progn (setf (getf (rest (getf (getf (first (last preceding-properties))
                                                                :special)
                                                          :closure-meta))
                                              :var-syms)
                                        (remove symbol
                                                (getf (rest (getf (getf (first (last preceding-properties))
                                                                        :special)
                                                                  :closure-meta))
                                                      :var-syms)))
                                  (if (and (getf (getf (first (last preceding-properties)) :special)
                                                 :closure-meta)
                                           (not (member symbol
                                                        (getf (rest (getf (getf (first
                                                                                 (last preceding-properties))
                                                                                :special)
                                                                          :closure-meta))
                                                              :fn-syms))))
                                      (push symbol (getf (rest (getf (getf (first (last preceding-properties))
                                                                           :special)
                                                                     :closure-meta))
                                                         :fn-syms)))))
                       (if (characterp precedent)
                           ;; account for the ⍺←function case
                           (if (eql '⍺ symbol)
                               `(a-set ⍺ ,(build-call-form precedent nil
                                                           (getf (first preceding-properties) :axes)))
                               (if (of-lexicons idiom precedent :functions)
                                   `(a-set ,(if at-top-level `(symbol-function '(inws ,symbol))
                                                `(inws ,symbol))
                                           ,(build-call-form precedent nil
                                                             (getf (first preceding-properties)
                                                                   :axes)))))
                           (if (and (listp symbol) (eql 'nspath (first symbol)))
                               (let ((path-symbol (intern (format-nspath (rest symbol)) space))
                                     (path-head (intern (string (macroexpand (second symbol))) space))
                                     (path-tail (loop :for sym :in (cddr symbol)
                                                      :collect (intern (string sym) "KEYWORD"))))
                                 ;; ensure the path to the function is valid
                                 (setf (symbol-function path-symbol) #'dummy-nargument-function)
                                 `(if (verify-nspath (symbol-value ',path-head) ',path-tail)
                                      (setf ,(macroexpand symbol) :function
                                            (symbol-value ',path-symbol) ,precedent)
                                      ;; TODO: should symbol-function be set above?
                                      (error "Invalid path for functon."))) ;; TODO: improve error message
                               `(a-set ,(if (and (listp symbol) (eql 'nspath (first symbol)))
                                           (follow-path (second symbol) (cddr symbol))
                                           (if at-top-level `(symbol-function (quote (inws ,symbol)))
                                               `(inws ,symbol)))
                                      ,precedent))))
                     '(:type (:function :assigned)) items))))

(composer-pattern operator-assignment (asop asop-props symbol symbol-props preceding-type)
    ;; "Match an operator assignment like f←{⍵×2}, part of a functional expression."
    ((setq preceding-type (getf (first preceding-properties) :type))
     (if (eq :operator (first preceding-type))
         (assign-element asop asop-props process-function '(:glyph ←)))
     (if asop (assign-element symbol symbol-props process-value '(:symbol-overriding t))))
  (if asop (values `(a-set ,(if (member :top-level (getf (first (last preceding-properties)) :special))
                                `(symbol-function (quote (inws ,symbol)))
                                `(inws ,symbol))
                           ,precedent)
                   '(:type (:operator :assigned)) items)))

(composer-pattern branch (asop asop-props branch-from from-props preceding-type)
    ;; "Match a branch-to statement like →1 or a branch point statement like 1→⎕."
    ((setq preceding-type (getf (first preceding-properties) :type))
     (if (eq :array (first preceding-type))
         (assign-element asop asop-props process-function '(:glyph →)))
     (if asop (assign-element branch-from from-props process-value)))
  (if asop (progn
             (if (listp precedent)
                 (if (loop :for item :in precedent :always (and (listp item) (eql 'inws (first item))))
                     (setq precedent (mapcar #'second precedent))
                     (if (eql 'inws (first precedent))
                         (setq precedent (second precedent)))))
             (values
              (if (and branch-from (eql 'to-output precedent))
                  ;; if this is a branch point statement like X→⎕, do the following:
                  (if (integerp branch-from)
                      ;; if the branch is designated by an integer like 5→⎕
                      (let ((branch-symbol (gensym "AB"))) ;; AB for APL Branch
                        (setf *branches* (cons (list branch-from branch-symbol) *branches*))
                        branch-symbol)
                      ;; if the branch is designated by a symbol like doSomething→⎕
                      (if (symbolp branch-from)
                          (progn (setf *branches* (cons branch-from *branches*))
                                 branch-from)
                          (error "Invalid left argument to →; must be a single integer value or a symbol.")))
                  ;; otherwise, this is a branch-to statement like →5 or →doSomething
                  (if (or (integerp precedent)
                          (symbolp precedent))
                      ;; if the target is an explicit symbol as in →mySymbol, or explicit index
                      ;; as in →3, just pass the symbol through
                      (list 'go precedent)
                      (if (loop :for item :in (rest precedent)
                             :always (or (symbolp item)
                                         (and (listp item) (eql 'inws (first item)))))
                          ;; if the target is one of an array of possible destination symbols...
                          (if (integerp branch-from)
                              ;; if there is an explicit index to the left of the arrow,
                              ;; grab the corresponding symbol unless the index is outside the
                              ;; array's scope, in which case a (list) is returned so nothing is done
                              (if (< 0 branch-from (length (rest precedent)))
                                  (list 'go (second (nth (1- branch-from) (rest precedent))))
                                  (list 'list))
                              ;; otherwise, there must be an expression to the left of the arrow, as with
                              ;; (3-2)→tagOne tagTwo, so pass it through for the postprocessor
                              (list 'go (mapcar #'second (rest precedent))
                                    branch-from))
                          (list 'go precedent))))
              '(:type (:branch)) items))))

(composer-pattern train-composition (center center-props is-center-function left left-props preceding-type)
    ;; "Match a train function composition like (-,÷)."
    ((setq preceding-type (getf (first preceding-properties) :type))
     (if (eq :function (first preceding-type))
         (progn (assign-subprocessed center center-props
                                     `(:special (:omit (:value-assignment :function-assignment
                                                        :train-composition)
                                                       ,@include-closure-meta-last)))
                (setq is-center-function (and center (eq :function (first (getf center-props :type)))
                                              (or (not (characterp center))
                                                  (not (char= #\← center)))))
                (if (and is-center-function (or (not (listp item))
                                                (not (eq :fn (first item)))
                                                (not (characterp (second item)))
                                                (not (char= #\← (second item)))))
                    (assign-subprocessed left left-props
                                         `(:special (:omit (:value-assignment
                                                            :function-assignment :branch :operator-assignment
                                                            :value-assignment-by-selection :operation)
                                                           ,@include-closure-meta-last)))))))
  (if is-center-function
      (if (not left)
          ;; if there's no left function, match an atop composition like 'mississippi'(⍸∊)'sp'
          (let* ((omega (gensym)) (alpha (gensym)) (right precedent)
                 (left-fn-monadic (if (not (and (characterp center)
                                                (of-lexicons idiom center :functions)))
                                      center (build-call-form center :monadic)))
                 (right-fn-monadic (if (not (characterp right))
                                       right (if (of-lexicons idiom right :functions-monadic)
                                                 (build-call-form right :monadic))))
                 (right-fn-dyadic (if (not (characterp right))
                                      right (if (of-lexicons idiom right :functions-dyadic)
                                                (build-call-form right :dyadic)))))
            (values `(lambda (,omega &optional ,alpha)
                       (if ,alpha (a-call ,left-fn-monadic (a-call ,right-fn-dyadic ,omega ,alpha))
                           (a-call ,left-fn-monadic (a-call ,right-fn-monadic ,omega))))
                    (list :type (list :function :train-atop-composition))))
          ;; if there's a left function, match a fork composition like (-,÷)5
          (destructuring-bind (right omega alpha center)
              (list precedent (gensym) (gensym)
                    (if (listp center)
                        center (if (characterp center)
                                   (if (of-lexicons idiom center :functions-dyadic)
                                       (build-call-form center :dyadic))
                                   (resolve-function center))))
            ;; train composition is only valid when there is only one function in the precedent
            ;; or when continuing a train composition as for (×,-,÷)5; remember that operator-composed
            ;; functions are also valid as preceding functions, as with (1+-∘÷)
            (if (and center (or (and (= 2 (length preceding-properties))
                                     (or (getf (getf (second preceding-properties) :special)
                                               :from-outside-functional-expression)
                                         (member :function (getf (first preceding-properties) :type))))
                                (and (member :function (getf (first preceding-properties) :type))
                                     (member :operator-composed (getf (first preceding-properties) :type)))
                                (member :train-fork-composition (getf (first preceding-properties) :type))))
                ;; functions are resolved here, failure to resolve indicates a value in the train
                (let ((right-fn-monadic (if (characterp right)
                                            (if (of-lexicons idiom right :functions-monadic)
                                                (build-call-form right :monadic))
                                            (if (and (listp right) (eql 'inws (first right)))
                                                `(inws ,(first (member (second right)
                                                                       (of-meta-hierarchy
                                                                        (rest (getf (getf properties :special)
                                                                                    :closure-meta))
                                                                        :fn-syms))))
                                                (if (and (listp right) (eql 'function (first right)))
                                                    right (resolve-function right)))))
                      (right-fn-dyadic (if (characterp right)
                                           (if (of-lexicons idiom right :functions-dyadic)
                                               (build-call-form right :dyadic))
                                           (if (and (listp right) (eql 'inws (first right)))
                                               `(inws ,(first (member (second right)
                                                                      (of-meta-hierarchy
                                                                       (rest (getf (getf properties :special)
                                                                                   :closure-meta))
                                                                       :fn-syms))))
                                               (if (and (listp right) (eql 'function (first right)))
                                                   right (resolve-function right)))))
                      (left-fn-monadic (if (characterp left)
                                           (if (of-lexicons idiom left :functions-monadic)
                                               (build-call-form left :monadic))
                                           (if (and (listp left) (eql 'inws (first left)))
                                               `(inws ,(first (member (second left)
                                                                      (of-meta-hierarchy
                                                                       (rest (getf (getf properties :special)
                                                                                   :closure-meta))
                                                                       :fn-syms))))
                                               (if (and (listp left) (eql 'function (first left)))
                                                   left (resolve-function left)))))
                      (left-fn-dyadic (if (characterp left)
                                          (if (of-lexicons idiom left :functions-dyadic)
                                              (build-call-form left :dyadic))
                                          (if (and (listp left) (eql 'inws (first left)))
                                              `(inws ,(first (member (second left)
                                                                     (of-meta-hierarchy
                                                                      (rest (getf (getf properties :special)
                                                                                  :closure-meta))
                                                                      :fn-syms))))
                                              (if (and (listp left) (eql 'function (first left)))
                                                  left (resolve-function left))))))
                  ;; TODO: can trains' generated code be more compact?
                  (let* ((right-call-d `(a-call ,right-fn-dyadic ,omega ,alpha))
                         (right-call-m `(a-call ,right-fn-monadic ,omega))
                         (lcm-fun (second (getf (getf left-props :call-refs) :monadic)))
                         (lcd-fun (second (getf (getf left-props :call-refs) :dyadic)))
                         (call-form `(lambda (,omega &optional ,alpha)
                                       (if ,alpha
                                           (a-call ,center ,right-call-d
                                                   ,(if (getf left-props :call-refs)
                                                        `(a-call ,lcd-fun ,omega ,alpha)
                                                        (if (not left-fn-dyadic)
                                                            left `(a-call ,left-fn-dyadic ,omega ,alpha))))
                                           (a-call ,center ,right-call-m
                                                   ,(if (getf left-props :call-refs)
                                                        `(a-call ,lcm-fun ,omega ,alpha)
                                                        (if (not left-fn-monadic)
                                                            left `(a-call ,left-fn-monadic ,omega))))))))
                    (values (if (getf left-props :call-refs)
                                (progn (setf (second (getf (getf left-props :call-refs) :monadic)) call-form
                                             (second (getf (getf left-props :call-refs) :dyadic)) call-form)
                                       left)
                                call-form)
                            (list :type (list :function :train-fork-composition)
                                  :call-refs (list :monadic right-call-m :dyadic right-call-d))
                            items))))))))

(composer-pattern lateral-inline-composition
    (operator operator-props left-operand-axes left-operand left-operand-props left-value
              left-value-props prior-items preceding-type)
    ;; Match an inline lateral operator composition like +{⍺⍺ ⍵}5.
    ((setq preceding-type (getf (first preceding-properties) :type))
     (assign-element operator operator-props process-operator
                     `(:valence :lateral :special (:closure-meta ,(getf (getf properties :special)
                                                                        :closure-meta))))
     (if operator (progn (assign-axes left-operand-axes process)
                         (setq prior-items items)
                         (assign-element left-operand left-operand-props process-function)
                         ;; if the next function is symbolic, assign it uncomposed;
                         ;; this is needed for things like ∊∘.+⍨10 2 to work correctly
                         (if (and items (not (member :symbolic-function (getf left-operand-props :type))))
                             (progn (setq items prior-items item (first items) rest-items (rest items))
                                    ;; the special :omit property makes it so that the pattern matching
                                    ;; the operand may not be processed as a value assignment, function
                                    ;; assignment or operation, which allows for expressions like
                                    ;; fn←5∘- where an operator-composed function is assigned
                                    (assign-subprocessed
                                     left-operand left-operand-props
                                     `(:special (:omit (:value-assignment :function-assignment :operation
                                                                          :train-composition)
                                                       ,@include-closure-meta-last)))
                                    ;; try getting a value on the left, as for 3 +{⍺ ⍺⍺ ⍵} 4
                                    (if (member :dyadic (getf operator-props :type))
                                        (assign-subprocessed
                                         left-value left-value-props
                                         `(:special (:omit (:operation :value-assignment
                                                            :function-assignment :train-composition)
                                                     ,@include-closure-meta)))))))))
  (if operator
      ;; get left axes from the left operand and right axes from the precedent's properties so the
      ;; functions can be properly curried if they have axes specified
      (let ((left-operand (insym left-operand))
            ;; need to check whether the operand is a character, else in '*' {⍶,⍵} ' b c d'
            ;; the * will be read as the [* exponential] function
            (is-operand-character (and (characterp left-operand)
                                       (member :array (getf left-operand-props :type)))))
        (values (if (and (listp operator) (member :lateral (getf operator-props :type)))
                    `(a-call (a-comp :op ,operator ,(if (and (characterp left-operand)
                                                             (not is-operand-character))
                                                        (build-call-form left-operand :dyadic)
                                                        ;; handle ∇ function self-reference
                                                        (if (and (symbolp left-operand) (eql '∇ left-operand))
                                                            '#'∇self left-operand)))
                             ,precedent ,@(if left-value (list left-value))))
                '(:type (:array :evaluated)) items))))

(composer-pattern pivotal-composition
    (operator operator-props left-operand-axes left-operand left-operand-props prior-items preceding-type env-pops symbol-plain)
    ;; Match a pivotal function composition like ×.+, part of a functional expression.
    ;; It may come after either a function or an array, since some operators take array operands.
    ((setq preceding-type (getf (first preceding-properties) :type))
     (setq symbol-plain item)
     (assign-element operator operator-props process-operator
                     `(:valence :pivotal
                                :special (,@include-closure-meta)))
     (if operator (progn (assign-axes left-operand-axes process)
                         (setq prior-items items
                               env-pops
                               (of-meta-hierarchy (rest (getf (getf properties :special) :closure-meta))
                                                  :pop-syms))
                         (assign-element left-operand left-operand-props process-function)
                         ;; if the next function is symbolic, assign it uncomposed;
                         ;; this is needed for things like ∊∘.+⍨10 2 to work correctly
                         (if (and (or items left-operand)
                                  (not (member :symbolic-function (getf left-operand-props :type))))
                             (progn (setq items prior-items item (first items) rest-items (rest items))
                                    ;; the special :omit property makes it so that the pattern matching
                                    ;; the operand may not be processed as a value assignment, function
                                    ;; assignment or operation, which allows for expressions like
                                    ;; fn←5∘- where an operator-composed function is assigned
                                    (assign-subprocessed
                                     left-operand left-operand-props
                                     `(:special
                                       (:omit (:value-assignment :function-assignment
                                                                 :operation :train-composition)
                                              ,@include-closure-meta))))))))
  (if (and operator left-operand)
      ;; get left axes from the left operand and right axes from the precedent's properties so the
      ;; functions can be properly curried if they have axes specified
      (let* ((right-operand (insym precedent))
             (right-operand-props (first preceding-properties))
             (right-operand-axes (getf (first preceding-properties) :axes))
             (left-operand (insym left-operand)))
        ;; TODO: make sure single-character values like '*' passed as operands don't get read as functions
        (values (if (or (symbolp operator) (and (listp operator)
                                                (member :pivotal (getf operator-props :type))))
                    `(a-comp :op ,(if (eq :operator-self-reference operator)
                                      '∇oself (if (listp operator)
                                                  operator
                                                  (list (if (and (fboundp (intern (string operator)
                                                                                  space))
                                                                 (not (member symbol-plain env-pops)))
                                                            'inwsd 'inws)
                                                        operator)))
                             ,(if (not (and (characterp left-operand)
                                            (of-lexicons idiom left-operand :functions)))
                                  left-operand (build-call-form left-operand))
                             ,(if (not (and (characterp right-operand)
                                            (of-lexicons idiom right-operand :functions)))
                                  right-operand (build-call-form right-operand)))
                    (let ((left (if (eql '∇ left-operand)
                                    '#'∇self
                                    (if (not (and (characterp left-operand)
                                                  (not (member :array (getf left-operand-props :type)))
                                                  (of-lexicons idiom left-operand :functions)))
                                        left-operand (build-call-form left-operand nil left-operand-axes))))
                          (right (if (eql '∇ right-operand)
                                     '#'∇self
                                     (if (not (and (characterp right-operand)
                                                   (not (member :array (getf right-operand-props :type)))
                                                   (of-lexicons idiom right-operand :functions)))
                                         right-operand (build-call-form right-operand nil right-operand-axes)))))
                      (cons 'a-comp (cons (intern (string-upcase operator) *package-name-string*)
                                          (funcall (symbol-function
                                                    (intern (format nil "APRIL-LEX-OP-~a" operator)
                                                            *package-name-string*))
                                                   right left)))))
                '(:type (:function :operator-composed :pivotal))
                items))))

(composer-pattern operation
    ;; Match an operation on values like 1+1 2 3, ⍳9 or +/⍳5; these operations are the basis of APL.
    (function-axes fn-element function-props is-function value value-props prior-items preceding-type)
    ((setq preceding-type (getf (first preceding-properties) :type))
     (if (eq :array (first preceding-type))
         (progn (assign-subprocessed fn-element function-props
                                     `(:special (:omit (:function-assignment :value-assignment-by-selection
                                                                             :lateral-inline-composition
                                                                             :train-composition :operation)
                                                       ,@include-closure-meta-last)))
                (setq is-function (eq :function (first (getf function-props :type)))
                      prior-items items)
                (if is-function (assign-subprocessed
                                 value value-props
                                 `(:special (:omit (:value-assignment
                                                    :function-assignment :operator-assignment
                                                    :value-assignment-by-selection :branch
                                                    :value-assignment-by-function-result :operation
                                                    :lateral-composition :lateral-inline-composition)
                                                   ,@include-closure-meta-last
                                                   :valence :lateral))))
                (if (not (eq :array (first (getf value-props :type))))
                    (setq items prior-items value nil))
                (if (and (not function-axes) (member :axes function-props))
                    (setq function-axes (getf function-props :axes))))))
  (if is-function (let ((fn-content (if (and (symbolp fn-element) (eql '∇ fn-element))
                                        ;; the ∇ symbol resolving to :self-reference generates the
                                        ;; #'∇self function used as a self-reference by lambdas invoked
                                        ;; through the (alambda) macro
                                        '#'∇self
                                        (if (or (functionp fn-element)
                                                (and (symbolp fn-element)
                                                     (member fn-element '(⍺⍺ ⍵⍵ ∇ ∇∇)))
                                                (and (listp fn-element)
                                                     (eql 'inws (first fn-element))
                                                     (member (second fn-element)
                                                             (of-meta-hierarchy
                                                              (rest (getf (getf properties :special)
                                                                          :closure-meta))
                                                              :fn-syms)))
                                                (and (listp fn-element)
                                                     (eql 'function (first fn-element))))
                                            fn-element (if (characterp fn-element)
                                                           (if (of-lexicons idiom fn-element :functions)
                                                               (build-call-form fn-element
                                                                                (if value :dyadic
                                                                                    :monadic)
                                                                                function-axes))
                                                           (or (of-lexicons idiom fn-element :functions)
                                                               fn-element))))))
                    (values `(a-call ,fn-content ,precedent ,@(if value (list value)))
                            '(:type (:array :evaluated)) items))))
    
(defvar *composer-following-patterns*)

(setq *composer-following-patterns*
      '((:name :value-assignment-by-function-result :function value-assignment-by-function-result)
        (:name :value-assignment-by-selection :function value-assignment-by-selection)
        (:name :value-assignment-standard :function value-assignment-standard)
        (:name :function-assignment :function function-assignment)
        (:name :operator-assignment :function operator-assignment)
        (:name :branch :function branch)
        (:name :train-composition :function train-composition)
        (:name :lateral-inline-composition :function lateral-inline-composition)
        (:name :pivotal-composition :function pivotal-composition)
        (:name :operation :function operation)))

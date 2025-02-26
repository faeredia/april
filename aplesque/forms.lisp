;;; -*- Mode:Lisp; Syntax:ANSI-Common-Lisp; Coding:utf-8; Package:Aplesque -*-
;;;; forms.lisp

(in-package #:aplesque)

"A set of functions defining the forms of arrays produced by the Aplesque array processing functions."

(defun indexer-section (inverse dims dimensions output-shorter)
  "Return indices of an array sectioned as with the [↑ take] or [↓ drop] functions."
  (let* ((isize (reduce #'* dims)) (irank (length dims))
         (rdiff (- irank (length dimensions)))
         (idims (make-array irank :element-type (if (zerop isize) t (list 'integer 0 isize))
                                  :initial-contents dims))
         (odims (loop :for odim :across dimensions :for idim :across idims
                      :collect (if (not inverse) (abs odim) (- idim (abs odim)))))
         (osize (reduce #'* odims))
         (last-dim)
         (id-factors (make-array irank :element-type 'fixnum))
         (od-factors (make-array irank :element-type 'fixnum)))
    ;; generate dimensional factors vectors for input and output
    (loop :for dx :below irank
          :do (let ((d (aref idims (- irank 1 dx))))
                (setf (aref id-factors (- irank 1 dx))
                      (if (zerop dx) 1 (* last-dim (aref id-factors (- irank dx))))
                      last-dim d)))

    (loop :for d :in (reverse odims) :for dx :from 0
          :do (setf (aref od-factors (- irank 1 dx))
                    (if (zerop dx) 1 (* last-dim (aref od-factors (- irank dx))))
                    last-dim d))
    (lambda (i)
      (if output-shorter
          ;; choose shorter path depending on whether input or output are larger, and
          ;; always iterate over output in the case of sub-7-bit arrays as this is necessary
          ;; to respect the segmentation of the elements
          (let ((oindex 0) (remaining i) (valid t))
            ;; calculate row-major offset for outer array dimensions
            (loop :for i :from 0 :to (- irank 1) :while valid
                  :for dim :across dimensions :for id :across idims :for od :in odims
                  :for ifactor :across id-factors :for ofactor :across od-factors
                  :do (multiple-value-bind (index remainder) (floor remaining ifactor)
                        (let ((adj-index (- index (if inverse (if (> 0 dim) 0 dim)
                                                      (if (< 0 dim) 0 (+ dim id))))))
                          (if (< -1 adj-index od)
                              (progn (incf oindex (* ofactor adj-index))
                                     (setq remaining remainder))
                              (setq valid nil)))))
            (if valid oindex))
          (let ((iindex 0) (remaining i) (valid t))
            ;; calculate row-major offset for outer array dimensions
            (loop :for i :from 0 :to (- irank 1) :while valid
                  :for dim :across dimensions :for id :across idims :for od :in odims
                  :for ifactor :across id-factors :for ofactor :across od-factors
                  :do (multiple-value-bind (index remainder) (floor remaining ofactor)
                        (let ((adj-index (+ index (if inverse (if (> 0 dim) 0 dim)
                                                      (if (< 0 dim) 0 (+ dim id))))))
                          (if (< -1 adj-index id)
                              (progn (incf iindex (* ifactor adj-index))
                                     (setq remaining remainder))
                              (setq valid nil)))))
            (if valid iindex))))))

(defun indexer-expand (degrees dims axis compress-mode)
  "Return indices of an array expanded as with the [/ compress] or [\ expand] functions."
  (let* ((c-degrees (make-array (length degrees) :element-type 'fixnum :initial-element 0))
         (positive-index-list (if (not compress-mode)
                                  (loop :for degree :below (length degrees)
                                        :when (< 0 (aref degrees degree)) :collect degree)))
         (positive-indices (if positive-index-list (make-array (length positive-index-list)
                                                               :element-type 'fixnum
                                                               :initial-contents positive-index-list)))
         (section-size (reduce #'* (loop :for d :in dims :for dx :from 0
                                         :when (> dx axis) :collect d))))
    (loop :for degree :across degrees :for dx :from 0
          :summing (max (abs degree) (if compress-mode 0 1))
            :into this-dim :do (setf (aref c-degrees dx) this-dim))
    (let ((idiv-size (reduce #'* (loop :for d :in dims :for dx :from 0
                                       :when (>= dx axis) :collect d)))
          (odiv-size (reduce #'* (loop :for d :in dims :for dx :from 0
                                       :when (> dx axis) :collect d :when (= dx axis)
                                         :collect (aref c-degrees (1- (length degrees)))))))
      (lambda (i)
        ;; in compress-mode: degrees must = length of axis,
        ;; zeroes are omitted from output, negatives add zeroes
        ;; otherwise: zeroes pass through, negatives add zeroes, degrees>0 must = length of axis
        (if dims
            (multiple-value-bind (oseg remainder) (floor i odiv-size)
              (multiple-value-bind (oseg-index element-index) (floor remainder section-size)
                ;; dimension index
                (let ((dx (loop :for d :across c-degrees :for di :from 0
                                :when (> d oseg-index) :return di)))
                  (if (< 0 (aref degrees dx))
                      (+ element-index (* oseg idiv-size)
                         (* section-size (if (not positive-indices)
                                             dx (or (loop :for p :across positive-indices
                                                          :for px :from 0 :when (= p dx)
                                                          :return px)
                                                    1)))))))))))))

(defun indexer-turn (axis idims degrees)
  "Return indices of an array rotated as with the [⌽ rotate] or [⊖ rotate first] functions."
  (let* ((rlen (nth axis idims))
         (increment (reduce #'* (nthcdr (1+ axis) idims)))
         (vset-size (* increment (nth axis idims))))
    (lambda (i)
      (+ (mod i increment)
         (* vset-size (floor i vset-size))
         (* increment (funcall (if degrees #'identity (lambda (x) (abs (- x (1- rlen)))))
                               (mod (+ (floor i increment)
                                       (if (integerp degrees)
                                           degrees (if (arrayp degrees)
                                                       (row-major-aref
                                                        degrees
                                                        (+ (mod i increment)
                                                           (* increment (floor i vset-size))))
                                                       0)))
                                    rlen)))))))

(defun indexer-permute (idims odims alpha is-diagonal)
  "Return indices of an array permuted as with the [⍉ permute] function."
  (let* ((irank (length idims))
         (positions) (diagonals) (idims-reduced) (idfactor 1) (odfactor 1)
         (id-factors (coerce (reverse (loop :for d :in (reverse idims)
                                            :collect idfactor :do (setq idfactor (* d idfactor))))
                             'vector))
         (indices (if alpha (progn (if (vectorp alpha)
                                       (loop :for i :across alpha :for id :in idims :for ix :from 0
                                             :do (if (not (member i positions))
                                                     ;; if a duplicate position is found,
                                                     ;; a diagonal section is being performed
                                                     (progn (push i positions)
                                                            (push id idims-reduced)))
                                                ;; collect possible diagonal indices into diagonal list
                                                (if (assoc i diagonals)
                                                    (push ix (rest (assoc i diagonals)))
                                                    (push (list i ix) diagonals))
                                             :collect i)
                                       (progn (setq odims idims
                                                    positions (cons alpha positions))
                                              (list alpha))))
                      (reverse (iota irank))))
         ;; remove indices not being used for diagonal section from diagonal list
         ;; the idims-reduced are a set of the original dimensions without dimensions being elided
         ;; for diagonal section, used to get the initial output array used for diagonal section
         (od-factors (make-array (length odims)))
         (s-factors (make-array irank)))
    (loop :for d :in (reverse odims) :for dx :from 0
          :do (setf (aref od-factors (- (length odims) 1 dx)) odfactor
                    odfactor (* d odfactor)))
    (loop :for i :across id-factors :for ix :from 0
          :do (setf (aref s-factors (nth ix indices)) i))
    (lambda (i)
      (if (not is-diagonal)
          ;; handle regular permutation cases
          (let* ((remaining i) (oindex 0))
            (loop :for ix :in indices :for od :across od-factors :for s :across s-factors
                  :collect (multiple-value-bind (index remainder) (floor remaining od)
                             (incf oindex (* index s))
                             (setq remaining remainder)))
            oindex)
          ;; handle diagonal array traversals
          (let ((remaining i) (iindex 0))
            (loop :for ox :from 0 :for of :across od-factors
                  :do (multiple-value-bind (index remainder) (floor remaining of)
                        (setq remaining remainder)
                        (loop :for a :in indices :for ax :from 0 :when (= a ox)
                              :do (incf iindex (* index (aref id-factors ax))))))
            iindex)))))

;; a sub-package of Aplesque that provides the array formatting functions
(defpackage #:aplesque.forms
  (:import-from :aplesque #:indexer-section #:indexer-expand #:indexer-turn #:indexer-permute)
  (:export #:indexer-section #:indexer-expand #:indexer-turn #:indexer-permute))

th train.lua -input_h5 /data/coco/coco.h5 \
              -input_json /data/coco/coco_vocab.json \
 	      -gpu 0 \
 	      -batch_size 10 \
 	      -seq_length 49 \
 	      -model_type "lstm" \
 	      -wordvec_size 512 \
 	      -rnn_size 2048 \
 	      -num_layers 1 \
 	      -learning_rate 0.001 \
              -checkpoint_every 10

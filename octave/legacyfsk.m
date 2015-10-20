% legacyfsk.m
% David Rowe October 2015
%
% Attempt at FSK waveform that can pass through legacy FM radios
% but still be optimally demodulated by SDRs. It doesn't have to be
% optimally demodulated by legacy radios.  Trick is getting it to
% pass through 300-3000Hz audio filters in leagcy radios.
%
% [X] code up modulator
%     [X] manchester two bit symbols
%     [X] plot spectrum
% [ ] demodulate
% [ ] measure BER compared to ideal coherent FSK
% [ ] measure and adjust for tone inversion through FM demod

1;

fm; % analog FM library


function states = legacyfsk_init()
  Fs = states.Fs = 96000;
  Rs = states.Rs = 4800;                       % symbol rate over channel
  Ts = states.Ts = Fs/Rs;                      % symbol period in samples
  M  = states.M  = 4;                          % mFSK, either 2 or 4
  bpsym = state.Rb  = log2(M);                 % bits per symbol over channel
  rate = states.rate = 0.5;                    % Manchester code rate
  nbits = 100;
  nbits = states.nbits = 100;                  % number of payload data symbols/frame
  nbits2 = states.nbits2 = nbits/rate;         % number of symbols/frame over channel after manchester encoding
  nsym  = states.nsym = nbits2/log2(M);        % number of symbols per frame
  nsam = states.nsam = nsym*Ts;

  printf("Rs: %d M: %d bpsym: %d nbits: %d nbits2: %d nsym: %d nsam: %d\n", Rs, M, bpsym, nbits, nbits2, nsym, nsam);

  states.fc = states.Fs/4;
  if states.M == 2
    states.f(1) = states.fc - Rs/2;
    states.f(2) = states.fc + Rs/2;
  else
    states.f(1) = states.fc - 3*Rs/2;
    states.f(2) = states.fc - Rs/2;
    states.f(3) = states.fc + Rs/2;
    states.f(4) = states.fc + 3*Rs/2;   
  end
endfunction


% test modulator function

function tx = legacyfsk_mod(states, tx_bits)
    Fs = states.Fs;
    Ts = states.Ts;
    Rs = states.Rs;
    f  = states.f;
    M  = states.M;
    nsym = states.nsym;

    tx = zeros(Ts*length(tx_bits)/log2(M),1);
    tx_phase = 0;

    step = log2(M);
    k = 1;
    for i=1:step:length(tx_bits)
      if M == 2
        tone = tx_bits(i) + 1;
      else
        tone = (tx_bits(i:i+1) * [2 1]') + 1;
      end
      tx_phase_vec = tx_phase + (1:Ts)*2*pi*f(tone)/Fs;
      tx((k-1)*Ts+1:k*Ts) = 2.0*cos(tx_phase_vec); k++;
      tx_phase = tx_phase_vec(Ts) - floor(tx_phase_vec(Ts)/(2*pi))*2*pi;
    end
   
endfunction


function run_sim

  frames = 100;
  timing_offset = 0.0;
  test_frame_mode = 1;
  demod = 2;

  if demod == 1
    EbNodB = 8.5+5;
  else
    EbNodB = 8.5;
  end
  EbNodB = 6;

  % init fsk modem

  more off
  rand('state',1); 
  randn('state',1);
  states = legacyfsk_init();
  Fs = states.Fs;
  nbits = states.nbits;
  nbits2 = states.nbits2;
  Ts = states.Ts;
  Rs = states.Rs;
  nsam = states.nsam;
  rate = states.rate;
  M = states.M;

  % init analog FM modem

  fm_states.Fs = Fs;  
  fm_max = fm_states.fm_max = 3E3;
  fd = fm_states.fd = 5E3;
  fm_states.fc = states.fc;

  fm_states.pre_emp = 0;
  fm_states.de_emp  = 1;
  fm_states.Ts = 1;
  fm_states.output_filter = 1;
  fm_states = analog_fm_init(fm_states);
  [b, a] = cheby1(4, 1, 300/Fs, 'high');   % 300Hz HPF to simulate FM radios

  % init sim states

  rx_bits_buf = zeros(1,2*nbits2);
  Terrs = Tbits = 0;
  state = 0;
  nerr_log = [];

  % set up the channel noise.  We have log(M)*rate payload bits/symbol
  % we have log2(M) bits/symbol, and rate bits per payload symbol 
  % TODO: explain this better as Im confused!
  
  EbNo = 10^(EbNodB/10);
  EsNo = EbNo*rate*log2(M);               
  variance = states.Fs/((states.Rs)*EsNo);  
  printf("EbNodB: %3.1f EbNo: %3.2f EsNo: %3.2f\n", EbNodB, EbNo, EsNo);

  % set up the input bits

  if test_frame_mode == 1
    % test frame of bits, which we repeat for convenience when BER testing
    test_frame = round(rand(1, nbits));
    tx_bits = [];
    for i=1:frames+1
      tx_bits = [tx_bits test_frame];
    end
  end
  if test_frame_mode == 2
    % random bits, just to make sure sync algs work on random data
    tx_bits = round(rand(1, nbits*(frames+1)));
  end
  if test_frame_mode == 3
    % ...10101... sequence
    tx_bits = zeros(1, nbits*(frames+1));
    tx_bits(1:2:length(tx_bits)) = 1;
  end

  % Manchester encoding, which removes DC term in baseband signal,
  % making the waveform friendly to old-school legacy FM radios with
  % voiceband filtering.  The "code rate" is 0.5, which means we have
  % encode one input bit into 2 output bits.  The 2FSK encoder takes
  % one input bit, the 4FSK encoder two input bits.

  tx_bits_encoded = zeros(1,length(tx_bits)*2);
  fsk2_enc = [[1 0]; [0 1]];
  %           -1.5 1.5    1.5 -1.5  -0.5 0.5    0.5 -0.5
  %              0   3      3   0      1   2      2   1
  fsk4_enc = [[0 0 1 1]; [1 1 0 0]; [0 1 1 0]; [1 0 0 1]];
  k=1;
  if M == 2
    for i=1:2:length(tx_bits_encoded)
      input_bit = tx_bits(k); k++;
      tx_bits_encoded(i:i+1) = fsk2_enc(input_bit+1,:);
    end
  else
    for i=1:4:length(tx_bits_encoded)
      input_bits = tx_bits(k:k+1) * [2 1]'; k+=2;
      tx_bits_encoded(i:i+3) = fsk4_enc(input_bits+1,:);
    end
  end
  tx_bits_encoded(1:6*2)
  % use ideal FSK modulator (note: need to try using analog FM modulator)

  tx = legacyfsk_mod(states, tx_bits_encoded);
  noise = sqrt(variance)*randn(length(tx),1);
  rx    = tx + noise;
  timing_offset_samples = round(timing_offset*Ts);
  rx = [zeros(timing_offset_samples,1); rx];

  if demod == 1
    % use analog FM demodulator, aka a $40 Baofeng

    [rx_out rx_bb] = analog_fm_demod(fm_states, rx');
    rx_out_hp = filter(b,a,rx_out);

    rx_timing = filter(ones(1,Ts),1,rx_out_hp);

    % TODO: for 4FSK determine amplitude/decn boundaries, choose closest to demod each symbol
  end

  if demod == 2

    % optimal non-coherent demod at Rs

    rx_timing_sig = zeros(1,length(rx));
    for m=1:M
      phi_vec = (1:length(rx))*2*pi*states.f(m)/Fs;
      dc = rx' .* exp(-j*phi_vec);
      rx_filt(m,:) = abs(filter(ones(1,Ts),1,dc));
      rx_timing_sig = rx_timing_sig + rx_filt(m,1:length(rx));
    end 
  end

  % Estimate fine timing using line at Rs/2 that Manchester encoding provides
  % We need this to sync up to Manchester codewords.  TODO plot signal and 
  % timing "line" we extract
  
  Np = length(rx_timing_sig);
  w = 2*pi*(Rs)/Fs;
  x = (rx_timing_sig .^ 2) * exp(-j*w*(0:Np-1))';
  norm_rx_timing = angle(x)/(2*pi) - 0.42;
  rx_timing = round(norm_rx_timing*Ts);
  rx_timing = 0;
  printf("norm_rx_timing: %4.4f rx_timing: %d\n", norm_rx_timing,  rx_timing);

  % sample at optimal instant

  [tmp l] = size(rx_filt);
  rx_filt_dec = rx_filt(:, Ts+rx_timing:Ts:l);

  % Max likelihood decoding of Manchester encoded symbols.  Search
  % through all ML possibilities to extract bits.  Use energy (filter
  % output sq)

  [tmp l] = size(rx_filt_dec);
  if M == 2
    rx_bits = zeros(1,l/2);
    k = 1;
    for i=1:2:l-1
      ml = [rx_filt_dec(2,i)*rx_filt_dec(1,i+1) rx_filt_dec(1,i)*rx_filt_dec(2,i+1)];
      [mx mx_ind] = max(ml);
     rx_bits(k) = mx_ind-1; k++;
    end 
  else
    rx_bits = zeros(1,l);
    k = 1;
    fsk4_dec = [[0 0]; [0 1]; [1 0]; [1 1]];
    for i=1:2:l-1
      %ml = [rx_filt_dec(1,i)*rx_filt_dec(4,i+1) rx_filt_dec(4,i)*rx_filt_dec(1,i+1) rx_filt_dec(2,i)*rx_filt_dec(3,i+1) rx_filt_dec(3,i)*rx_filt_dec(2,i+1)];
      ml = [(rx_filt_dec(1,i)+rx_filt_dec(4,i+1)) (rx_filt_dec(4,i)+rx_filt_dec(1,i+1)) (rx_filt_dec(2,i)+rx_filt_dec(3,i+1)) (rx_filt_dec(3,i)+rx_filt_dec(2,i+1))];
      [mx mx_ind] = max(ml);
      rx_bits(k:k+1) = fsk4_dec(mx_ind,:); k+=2;
    end 
  end

  % Run frame sync and BER logic over demodulated bits

  st = 1;
  for f=1:frames

    % extract nin bits

    nin = nbits;
    en = st + nin - 1;

    rx_bits_buf(1:nbits) = rx_bits_buf(nbits+1:2*nbits);
    rx_bits_buf(nbits+1:2*nbits) = rx_bits(st:en);

    st += nin;

    % frame sync based on min BER

    if test_frame_mode == 1
      nerrs_min = nbits;
      next_state = state;
      if state == 0
        for i=1:nbits
          error_positions = xor(rx_bits_buf(i:nbits+i-1), test_frame);
          nerrs = sum(error_positions);
          %printf("i: %d nerrs: %d nerrs_min: %d \n", i, nerrs, nerrs_min);
          if nerrs < nerrs_min
            nerrs_min = nerrs;
            coarse_offset = i;
          end
        end
        if nerrs_min < 3
          next_state = 1;
          %printf("%d %d\n", coarse_offset, nerrs_min);
        end
      end

      if state == 1  
        error_positions = xor(rx_bits_buf(coarse_offset:coarse_offset+nbits-1), test_frame);
        nerrs = sum(error_positions);
        Terrs += nerrs;
        Tbits += nbits;
        nerr_log = [nerr_log nerrs];
      end

      state = next_state;

    end 
  end

  if test_frame_mode == 1
    printf("frames: %d Tbits: %d Terrs: %d BER %4.3f\n", frames, Tbits, Terrs, Terrs/Tbits);
  end

  % Bunch O'plots --------------------------------------------------------------

  st = 1; en=10;

  Tx=fft(tx, Fs);
  TxdB = 20*log10(abs(Tx(1:Fs/2)));
  figure(1)
  clf;
  plot(TxdB)
  axis([1 Fs/2 (max(TxdB)-100) max(TxdB)])
  title('Tx Spectrum');

  figure(2)
  clf
  if demod == 1
    subplot(211)
    plot(rx_out(st:en*states.Ts*2));
    title('After Analog FM demod');
    subplot(212)
    plot(rx_out_hp(st:en*states.Ts*2));
    title('After 300Hz HPF');
  end
  if demod == 2
    subplot(211);
    plot(rx_filt(1,st*Ts:en*Ts));
    hold on;
    plot(rx_filt(2,st*Ts:en*Ts),'g');
    if M == 4
      plot(rx_filt(3,st*Ts:en*Ts),'c');
      plot(rx_filt(4,st*Ts:en*Ts),'r');          
    end
    hold off;
    title('Output of each filter');
    subplot(212);
    plot(rx_filt_dec(1,st:en),'+');
    hold on;
    plot(rx_filt_dec(2,st:en),'g+');
    if M == 4
      plot(rx_filt_dec(3,st:en),'c+');
      plot(rx_filt_dec(4,st:en),'r+');          
    end
    hold off;
    title('Decimated output of each filter');
  end

  figure(3);
  clf;
  if demod == 1
    subplot(211)
    h = freqz(b,a,Fs);
    plot(20*log10(abs(h(1:4000))))
    title('300Hz HPF Response');
    subplot(212)
    h = fft(rx_out, Fs);
    plot(20*log10(abs(h(1:4000))))
    title('Spectrum of baseband modem signal after analog FM demod');
  end

if 0
  figure(4);
  clf;
  subplot(211)
  plot(rx_sd(st*Ts:en*Ts),'+')
  title('Difference after filtering');
  subplot(212)
  plot(rx_sd_sampled(st:en),'+');
  hold on;
  plot(rx_sd_sampled(st:en),'g+')
  hold off;
  title('Both channels after sampling at ideal timing instant')
end
  
  figure(5)
  clf;  
  subplot(211)
  plot(rx_timing_sig(st*Ts:en*Ts).^2)
  subplot(212)
  F = abs(fft(rx_timing_sig(1:Fs)));
  plot(F(100:8000))
  title('FFT of rx_timing_sig')
end

run_sim;

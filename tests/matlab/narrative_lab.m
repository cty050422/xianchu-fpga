function narrative_lab(mode)
% Console-only demo: offline analysis first; recording requires menu selection.
% narrative_lab('check') checks files/Python without opening audio or JTAG.
here=fileparts(mfilename('fullpath'));
package=fileparts(fileparts(here));
script=fullfile(fileparts(here),'analysis','demo_analysis.py');
python=select_python();
if nargin>0 && strcmpi(mode,'check')
    invoke_python({'selfcheck'},false);
    fprintf('PASS：MATLAB菜单、Python和分析文件可用，未打开音频或JTAG。\n');
    return;
end
fprintf('\n弦触·云声：已有数据分析与录音\n');
fprintf('GAO负责片内波形/运算抓取；本菜单根据真实WAV绘制电脑端频谱。\n');
fprintf('新录音：%s\n分析结果：%s\n',fullfile(package,'05_新采集'),fullfile(package,'04_结果'));
while true
    fprintf('\n1 已有WAV：看波形、FFT和RMS包络\n');
    fprintf('2 录制10秒：55Hz/32分量持续测试音\n');
    fprintf('3 已有GAO Hex CSV：自动识别Core0/1/2并核验\n');
    fprintf('4 只检查分析环境\n0 退出\n');
    choice=strtrim(input('输入编号后回车：','s'));
    try
        switch choice
            case '1'
                [name,folder]=uigetfile('*.wav','选择真实录音WAV',fullfile(package,'干净数据'));
                if isequal(name,0),continue;end
                fprintf('1：55Hz/32分量持续测试音；2：普通演奏音。\n');
                stimulus=strtrim(input('录音内容（默认2）：','s'));
                args={'wav',fullfile(folder,name)};
                if strcmp(stimulus,'1'),args=[args,{'--expected-f0','55'}];end
                invoke_python(args,true);
            case '2'
                record_test_tone();
            case '3'
                [name,folder]=uigetfile('*.csv','选择已完成捕获的完整GAO Hex CSV',fullfile(package,'05_新采集'));
                if isequal(name,0),continue;end
                invoke_python({'gao',fullfile(folder,name)},true);
            case '4'
                invoke_python({'selfcheck'},false);
            case '0'
                return;
            otherwise
                fprintf('请输入0到4。\n');
        end
    catch err
        fprintf(2,'本次未完成：%s\n已保存的原件和分析结果保留。\n',err.message);
    end
end

    function record_test_tone()
        fprintf('\n本次录什么：55Hz低音A、32分量、持续测试音。\n');
        fprintf('请手动进入对应测试模式，保持音符、摇杆和电脑输入设置稳定。\n');
        fprintf('采用板上模拟音频口→AUX线→电脑Realtek外接麦克风输入。\n');
        fprintf('本入口记录当前输入设置；不会自动改变系统音量或音效。\n');
        fsPath=strtrim(input('实际烧录的.fs路径或版本说明；不清楚写未知：','s'));
        gainNote=strtrim(input('本次Windows输入音量/增强设置说明；不清楚写未知：','s'));
        if isempty(fsPath),fsPath='未知';end
        if isempty(gainNote),gainNote='未知';end
        devices=audiodevinfo;
        if isempty(devices.input),error('没有可用录音输入。');end
        names=string({devices.input.Name});
        pick=find((contains(names,'麦克风')|contains(lower(names),'microphone')) & ...
            contains(lower(names),'realtek') & ~contains(names,'阵列') & ...
            ~contains(lower(names),'array') & ~contains(names,'混音') & ~contains(lower(names),'mix'));
        if numel(pick)~=1,error('需要唯一Realtek外接麦克风输入；请先在Windows恢复该端点。');end
        device=devices.input(pick);fs=48000;
        if ~audiodevinfo(1,device.ID,fs,16,1),error('该输入不支持48kHz、16位、单声道。');end
        fprintf('输入设备：%s\n',device.Name);
        answer=strtrim(input('确认测试音已响，输入1并回车开始录10秒；其他输入返回：','s'));
        if ~strcmp(answer,'1'),fprintf('已返回，尚未打开录音设备。\n');return;end
        stamp=char(datetime('now','Format','yyyyMMdd_HHmmss_SSS'));
        folder=fullfile(package,'05_新采集',['AUDIO_55Hz32_' stamp]);
        if isfolder(folder),error('采集目录已存在，拒绝覆盖。');end
        mkdir(folder);
        meta=struct('created_at',char(datetime('now','Format','yyyy-MM-dd HH:mm:ss.SSS')), ...
            'evidence','REAL_PC_AUDIO_INPUT_RECORDING','stimulus','55Hz_32partial_continuous_test_tone', ...
            'expected_f0_hz',55,'expected_partials',32,'fs_hz',fs,'bits',16,'channels',1, ...
            'device_id',device.ID,'device_name',device.Name,'requested_seconds',10, ...
            'reported_programmed_image',fsPath,'hardware_identity_verified',false, ...
            'input_setting_operator_note',gainNote,'os_gain_api_verified',false, ...
            'audio_effects_verified_off',false,'route_operator_confirmed',true,'normalization_applied',false);
        save_json(fullfile(folder,'capture.json'),meta);
        for k=3:-1:1,fprintf('%d...\n',k);pause(1);end
        recorder=audiorecorder(fs,16,1,device.ID);
        guard=onCleanup(@()stop(recorder));
        record(recorder,10);timer=tic;last=-1;
        fprintf('正在录：55Hz/32分量持续测试音，请保持状态。\n');
        while isrecording(recorder)
            second=min(10,floor(toc(timer)));
            if second~=last,fprintf('  %d / 10秒\n',second);last=second;end
            drawnow;pause(.1);
        end
        stop(recorder);samples=getaudiodata(recorder,'double');
        if isempty(samples),error('设备没有返回音频样本。');end
        wav=fullfile(folder,'raw_capture.wav');audiowrite(wav,samples,fs,'BitsPerSample',16);
        meta.actual_samples=numel(samples);meta.actual_seconds=numel(samples)/fs;meta.raw_wav_sha256=file_sha256(wav);
        meta.peak_fs=max(abs(samples));meta.rms_fs=sqrt(mean(samples.^2));
        save_json(fullfile(folder,'capture.json'),meta);
        clear guard;
        fprintf('原始WAV：%s\n',wav);
        invoke_python({'wav',wav,'--expected-f0','55'},true);
    end

    function invoke_python(args,openReport)
        parts=[{python,script},args];
        quoted=cell(size(parts));
        for j=1:numel(parts)
            value=char(parts{j});
            if contains(value,'"')||contains(value,newline),error('路径含不支持的引号或换行。');end
            quoted{j}=['"' value '"'];
        end
        if ispc && ~contains(python,' '),quoted{1}=python;end
        command=strjoin(quoted,' ');
        if ispc && contains(python,' '),command=['"' command '"'];end
        setenv('PYTHONUTF8','1');setenv('PYTHONDONTWRITEBYTECODE','1');
        [code,output]=system(command);fprintf('%s\n',output);
        try
            result=jsondecode(output);
            if isfield(result,'output')
                fprintf('本次结果：%s\n',result.output);
                report=fullfile(result.output,'report.html');
                if openReport && isfile(report),web(report,'-browser');end
            end
        catch
            % The selfcheck prints a one-line result rather than JSON.
        end
        if code~=0,error('分析未通过，原件保留；请查看本次analysis.json和错误说明。');end
    end
end

function executable=select_python()
choices={getenv('XIANCHU_PYTHON'),getenv('CHORUS_PYTHON'), ...
    fullfile(getenv('LOCALAPPDATA'),'Programs','Python','Python312','python.exe'), ...
    fullfile(getenv('USERPROFILE'),'AppData','Local','Programs','Python','Python312','python.exe')};
for k=1:numel(choices)
    if ~isempty(choices{k})&&isfile(choices{k}),executable=choices{k};return;end
end
[code,output]=system('where python');
if code==0
    paths=splitlines(strtrim(output));
    for k=1:numel(paths)
        if isfile(paths{k}) && ~contains(paths{k},'WindowsApps'),executable=char(paths{k});return;end
    end
end
error('未找到Python，请设置XIANCHU_PYTHON为含numpy/scipy/matplotlib的Python路径。');
end

function save_json(path,value)
fid=fopen(path,'w','n','UTF-8');if fid<0,error('无法写入元数据。');end
guard=onCleanup(@()fclose(fid));fprintf(fid,'%s\n',jsonencode(value,PrettyPrint=true));
end

function value=file_sha256(path)
digest=java.security.MessageDigest.getInstance('SHA-256');
fid=fopen(path,'rb');if fid<0,error('无法读取原始WAV。');end
guard=onCleanup(@()fclose(fid));
while ~feof(fid),digest.update(typecast(fread(fid,1048576,'*uint8'),'int8'));end
value=lower(reshape(dec2hex(typecast(digest.digest(),'uint8'),2).',1,[]));
end

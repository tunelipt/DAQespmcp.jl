
using PyCall
using DAQCore
import Dates: DateTime, now
import DataStructures: OrderedDict
export EspMcpClient, daqconfigdev,daqacquire
export daqstart, daqread, samplesread, isreading
export daqchannels, numchannels, devname, devtype, samplingrate

mutable struct EspMcpClient <: AbstractInputDev
    devname::String
    ip::String
    port::Int32
    server::PyObject
    config::DaqConfig
    chans::DaqChannels
    time::DateTime
    vref::Float64
    task::DaqTask
    usethread::Bool
end

function EspMcpClient(;devname="ESPMCP", ip="192.168.0.145", port=9541,
                      usethread=true, vref=2.5)
    xmlrpc = pyimport("xmlrpc.client")
    server = xmlrpc.ServerProxy("http://$ip:$port")
    
    config = DaqConfig(ip=ip, port=port, avg=100, fps=1, period=100)
    task = DaqTask()
    
    ch = DaqChannels("E" .* numstring.(1:32), collect(1:32))
    task = DaqTask()
    return EspMcpClient(devname, ip, port, server,
                        config, ch, now(), vref, task, usethread)
    
end

function tomltoespmcpclient(toml)
    haskey(toml, "type") || error("TOML should type!")
    t = toml["type"] 
    if  t != "espmcpclient"
        error("Unknown type $t")
    end

    # First we need the ip and port - XMLRPC stuff
    haskey(toml, "ip") || error("A XML-RPC DAQespmcp client should have the field `ip`")
    haskey(toml, "port") || error("A XML-RPC DAQespmcp client should have the field `port`")
    haskey(toml, "name") || error("Every daq device should have a name")

    if !haskey(toml, "vref")
        vref = 2.5
    else
        vref = toml["vref"]
    end
    
        
    ip = toml["ip"]
    port = toml["port"]
    name = toml["name"]

    # Channels: 1-32.
    if !haskey(toml, "channels")
        chans = 1:32
    else
        chans = Int.(tom["channels"])
    end

    # Let's get daq configuration
    haskey(toml, "config") || error("No configuration available!")

    fps = toml["config"]["fps"]
    avg = toml["config"]["avg"]
    period = toml["config"]["period"]

    # Now, let's build the object
    
    dev = EspMcpClient(; devname=name, ip=ip, port=port, vref=vref)
    daqaddinput(dev, chans)
    
    daqconfigdev(dev, fps=fps, avg=avg, period=period)
    return dev
    
end

DAQCore.devtype(dev::EspMcpClient) = "ESPMCPClient"


function Base.show(io::IO, dev::EspMcpClient)
    println(io, "EspMcpClient")
    println(io, "    Dev Name: $(devname(dev))")
    println(io, "    IP: $(string(dev.ip))")
    println(io, "    port: $(string(dev.port))")
end



function DAQCore.daqaddinput(dev::EspMcpClient, chans=1:32; names="E")
    
    cmin, cmax = extrema(chans)
    if cmin < 1 || cmax > 32
        throw(ArgumentError("Only channels 1-32 are available to ESPMCP"))
    end

    if isa(names, AbstractString) || isa(names, Symbol) || isa(names, AbstractChar)
        chn = string(names) .* numstring.(chans, 2)
    elseif length(names) == length(chans)
        chn = string.(names)
    else
        throw(ArgumentError("Argument `names` should have length 1 or the length of `chans`"))
    end

    ch = DaqChannels(chn, collect(chans))
    dev.chans = ch
    return
end

function DAQCore.daqconfigdev(dev::EspMcpClient; kw...)
    k = keys(kw)
    cmd = Dict("avg"=>"A", "fps"=>"F", "period"=>"P")
    args = Pair{String,Int}[]

    if :avg ∈ k
        x = kw[:avg]
        if x < 1 || x > 500
            throw(DomainError(x, "avg outside range (1-500)!"))
        end
        dev.server["avg"](x)
        iparam!(dev.config, "avg", x)
    end

    if :fps ∈ k
        x = kw[:fps]
        if x < 1 || x > 60_000
            throw(DomainError(x, "fps outside range (1-60000)!"))
        end
        dev.server["fps"](x)
        iparam!(dev.config, "fps", x)
    end
    if :period ∈ k
        x = kw[:period]
        if x < 10 || x > 1000
            throw(DomainError(x, "period outside range (1-60000)!"))
        end
        dev.server["period"](x)
        iparam!(dev.config, "period", x)
    end

    return
end

function DAQCore.daqstart(dev::EspMcpClient)
    dev.time = now()
    dev.server["start"]()
end

function parse_frame(frame)
    io = IOBuffer(frame)
    header = read(io, Int32)
    t = read(io, Int32)
    idx = read(io, Int32)
    raw = [read(io, UInt16) for i in 1:32]
    footer = read(io, Int32)

    return header, t, idx, raw, footer
end

function read_data(dev::EspMcpClient, frames)
    d = [parse_frame(f.data) for f in frames]
    

    nf = length(d)
    x = zeros(Float64, 32, nf)

    for i in 1:nf
        r = d[i][4]
        for k in 1:32
            x[k,i] = (r[k]/4095) * dev.vref
        end
    end
    if nf == 1
        rate = 1000/iparam(dev.config, "period")
    else
        ttot = (d[end][2] - d[1][2]) / 1000
        rate = (nf-1) / ttot
    end
    samp = DaqSamplingRate(rate, nf, dev.time)

    nch = numchannels(dev)
    units = ["V" for i in 1:nch]

    return MeasData(devname(dev), devtype(dev), samp,
                    x[dev.chans.physchans,:], dev.chans, units)
end

function DAQCore.daqread(dev::EspMcpClient)
    frames = dev.server["read_raw"]()
    return read_data(dev, frames)
end

function DAQCore.daqacquire(dev::EspMcpClient)
    frames = dev.server["scan_raw"]()
    return  read_data(dev, frames)
end



"Is EspMcpClient acquiring data?"
DAQCore.isreading(dev::EspMcpClient) = dev.server["isacquiring"]()

"How many samples have been read?"
DAQCore.samplesread(dev::EspMcpClient) = dev.server["samplesread"]()


DAQCore.daqchannels(dev::EspMcpClient) = daqchannels(dev.chans)

DAQCore.numchannels(dev::EspMcpClient) = numchannels(dev.chans)




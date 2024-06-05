{
    Copyright (C) 2024 VCC
    creation date: 26 Mar 2024
    initial release date: 19 May 2024

    author: VCC
    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"),
    to deal in the Software without restriction, including without limitation
    the rights to use, copy, modify, merge, publish, distribute, sublicense,
    and/or sell copies of the Software, and to permit persons to whom the
    Software is furnished to do so, subject to the following conditions:
    The above copyright notice and this permission notice shall be included
    in all copies or substantial portions of the Software.
    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
    EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
    MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
    IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
    DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
    TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
    OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
}


unit FindSubControlWorkerMainForm;

{$IFNDEF IsMCU}
  {$DEFINE IsDesktop}
{$ENDIF}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  InMemFileSystem, PollingFIFO, DynArrays,
  TplZlibUnit, TplLzmaUnit,
  IdGlobal, IdTCPClient, IdHTTPServer, IdCoderMIME, IdSchedulerOfThreadPool,
  IdCustomHTTPServer, IdContext, IdCustomTCPServer, IdHTTP;

type

  { TfrmFindSubControlWorkerMain }

  TfrmFindSubControlWorkerMain = class(TForm)
    btnDisconnect: TButton;
    chkExtServerKeepAlive: TCheckBox;
    chkExtServerActive: TCheckBox;
    grpExtServer: TGroupBox;
    grpMQTT: TGroupBox;
    IdDecoderMIME1: TIdDecoderMIME;
    IdHTTP1: TIdHTTP;
    IdHTTPServer1: TIdHTTPServer;
    IdSchedulerOfThreadPool1: TIdSchedulerOfThreadPool;
    IdTCPClient1: TIdTCPClient;
    imgFindSubControlBackground: TImage;
    lbeUIClickerPort: TLabeledEdit;
    lblExtServerInfo: TLabel;
    lbeAddress: TLabeledEdit;
    lbeClientID: TLabeledEdit;
    lbePort: TLabeledEdit;
    lbeExtServerPort: TLabeledEdit;
    lblServerInfo: TLabel;
    memLog: TMemo;
    tmrConnect: TTimer;
    tmrSubscribe: TTimer;
    tmrProcessLog: TTimer;
    tmrProcessRecData: TTimer;
    tmrStartup: TTimer;
    procedure btnDisconnectClick(Sender: TObject);
    procedure chkExtServerActiveChange(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure IdHTTPServer1CommandGet(AContext: TIdContext;
      ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
    procedure IdHTTPServer1Connect(AContext: TIdContext);
    procedure IdHTTPServer1Exception(AContext: TIdContext; AException: Exception
      );
    procedure tmrConnectTimer(Sender: TObject);
    procedure tmrProcessLogTimer(Sender: TObject);
    procedure tmrProcessRecDataTimer(Sender: TObject);
    procedure tmrStartupTimer(Sender: TObject);
    procedure tmrSubscribeTimer(Sender: TObject);
  private
    FMQTTPassword: string;
    FLoggingFIFO: TPollingFIFO;
    FRecBufFIFO: TPollingFIFO; //used by the reading thread to pass data to MQTT library
    FInMemFS: TInMemFileSystem;

    procedure LogDynArrayOfByte(var AArr: TDynArrayOfByte; ADisplayName: string = '');

    procedure HandleClientOnConnected(Sender: TObject);
    procedure HandleClientOnDisconnected(Sender: TObject);

    procedure SendString(AString: string);
    procedure SendDynArrayOfByte(AArr: TDynArrayOfByte);
    procedure SendPacketToServer(ClientInstance: DWord);

    procedure AddToLog(AMsg: string);
    procedure SyncReceivedBuffer(var AReadBuf: TDynArrayOfByte);
    procedure ProcessReceivedBuffer;

    procedure InitHandlers;
  public

  end;

var
  frmFindSubControlWorkerMain: TfrmFindSubControlWorkerMain;

implementation

{$R *.frm}


uses
  MQTTUtils, MQTTClient, MQTTConnectCtrl, MQTTSubscribeCtrl, MQTTUnsubscribeCtrl
  {$IFDEF UsingDynTFT}
    , MemManager
  {$ENDIF}
  , DistFindSubControlCommonConsts, ClickerUtils, Types, ClickerActionProperties,
  ClickerActionsClient, ClickerExtraUtils, MemArchive;

var
  AssignedClientID: string;


procedure HandleOnMQTTError(ClientInstance: DWord; AErr: Word; APacketType: Byte);
var
  PacketTypeStr: string;
begin
  MQTTPacketToString(APacketType, PacketTypeStr);
  frmFindSubControlWorkerMain.AddToLog('Client: ' + IntToHex(ClientInstance, 8) + '  Err: $' + IntToHex(AErr) + '  PacketType: $' + IntToHex(APacketType) + ' (' + PacketTypeStr + ').');  //The error is made of an upper byte and a lower byte.

  if Hi(AErr) = CMQTT_Reason_NotAuthorized then   // $87
  begin
    frmFindSubControlWorkerMain.AddToLog('Server error: Not authorized.');
    if APacketType = CMQTT_CONNACK then
      frmFindSubControlWorkerMain.AddToLog('             on receiving CONNACK.');
  end;

  if Lo(AErr) = CMQTT_PacketIdentifierNotFound_ClientToServer then   // $CE
    frmFindSubControlWorkerMain.AddToLog('Client error: PacketIdentifierNotFound.');

  if Lo(AErr) = CMQTT_UnhandledPacketType then   // $CA
    frmFindSubControlWorkerMain.AddToLog('Client error: UnhandledPacketType.');  //Usually appears when an incomplete packet is received, so the packet type by is 0.
end;


procedure HandleOnSend_MQTT_Packet(ClientInstance: DWord; APacketType: Byte);
var
  PacketName: string;
begin
  MQTTPacketToString(APacketType, PacketName);
  frmFindSubControlWorkerMain.AddToLog('Sending ' + PacketName + ' packet...');

  try
    frmFindSubControlWorkerMain.SendPacketToServer(ClientInstance);
  except
    on E: Exception do
      frmFindSubControlWorkerMain.AddToLog('Cannot send ' + PacketName + ' packet... Ex: ' + E.Message);
  end;
end;


function HandleOnBeforeMQTT_CONNECT(ClientInstance: DWord;  //The lower byte identifies the client instance (the library is able to implement multiple MQTT clients / device). The higher byte can identify the call in user handlers for various events (e.g. TOnBeforeMQTT_CONNECT).
                                    var AConnectFields: TMQTTConnectFields;                    //user code has to fill-in this parameter
                                    var AConnectProperties: TMQTTConnectProperties;
                                    ACallbackID: Word): Boolean;
var
  TempWillProperties: TMQTTWillProperties;
  UserName, Password: string;
  //ClientId: string;
  //Id: Char;
  ConnectFlags: Byte;
  EnabledProperties: Word;
begin
  Result := True;

  frmFindSubControlWorkerMain.AddToLog('Preparing CONNECT data..');

  //Id := Chr((ClientInstance and $FF) + 48);
  //ClientId := 'MyClient' + Id;
  UserName := 'Username';
  Password := frmFindSubControlWorkerMain.FMQTTPassword;

  //StringToDynArrayOfByte(ClientId, AConnectFields.PayloadContent.ClientID);
  StringToDynArrayOfByte(UserName, AConnectFields.PayloadContent.UserName);
  StringToDynArrayOfByte(Password, AConnectFields.PayloadContent.Password);

  ConnectFlags := CMQTT_UsernameInConnectFlagsBitMask or
                  CMQTT_PasswordInConnectFlagsBitMask or
                  CMQTT_CleanStartInConnectFlagsBitMask {or
                  CMQTT_WillQoSB1InConnectFlagsBitMask};

  EnabledProperties := CMQTTConnect_EnSessionExpiryInterval or
                       CMQTTConnect_EnRequestResponseInformation or
                       CMQTTConnect_EnRequestProblemInformation {or
                       CMQTTConnect_EnAuthenticationMethod or
                       CMQTTConnect_EnAuthenticationData};

  MQTT_InitWillProperties(TempWillProperties);
  TempWillProperties.WillDelayInterval := 30; //some value
  TempWillProperties.PayloadFormatIndicator := 1;  //0 = do not send.  1 = UTF-8 string
  TempWillProperties.MessageExpiryInterval := 3600;
  StringToDynArrayOfByte('SomeType', TempWillProperties.ContentType);
  StringToDynArrayOfByte('SomeTopicName', TempWillProperties.ResponseTopic);
  StringToDynArrayOfByte('MyCorrelationData', TempWillProperties.CorrelationData);

  {$IFDEF EnUserProperty}
    AddStringToDynOfDynArrayOfByte('Key=Value', TempWillProperties.UserProperty);
    AddStringToDynOfDynArrayOfByte('NewKey=NewValue', TempWillProperties.UserProperty);
  {$ENDIF}

  FillIn_PayloadWillProperties(TempWillProperties, AConnectFields.PayloadContent.WillProperties);
  MQTT_FreeWillProperties(TempWillProperties);
  StringToDynArrayOfByte('WillTopic', AConnectFields.PayloadContent.WillTopic);

  //Please set the Will Flag in ConnectFlags below, then uncomment above code, if "Will" properties are required.
  AConnectFields.ConnectFlags := ConnectFlags;  //bits 7-0:  User Name, Password, Will Retain, Will QoS, Will Flag, Clean Start, Reserved
  AConnectFields.EnabledProperties := EnabledProperties;
  AConnectFields.KeepAlive := 0; //any positive values require pinging the server if no other packet is being sent

  AConnectProperties.SessionExpiryInterval := 3600; //[s]
  AConnectProperties.ReceiveMaximum := 7000;
  AConnectProperties.MaximumPacketSize := 10 * 1024 * 1024;
  AConnectProperties.TopicAliasMaximum := 100;
  AConnectProperties.RequestResponseInformation := 1;
  AConnectProperties.RequestProblemInformation := 1;

  {$IFDEF EnUserProperty}
    AddStringToDynOfDynArrayOfByte('UserProp=Value', AConnectProperties.UserProperty);
  {$ENDIF}

  StringToDynArrayOfByte('SCRAM-SHA-1', AConnectProperties.AuthenticationMethod);       //some example from spec, pag 108   the server may add to its log: "bad AUTH method"
  StringToDynArrayOfByte('client-first-data', AConnectProperties.AuthenticationData);   //some example from spec, pag 108

  frmFindSubControlWorkerMain.AddToLog('Done preparing CONNECT data..');
  frmFindSubControlWorkerMain.AddToLog('');
end;


procedure HandleOnAfterMQTT_CONNACK(ClientInstance: DWord; var AConnAckFields: TMQTTConnAckFields; var AConnAckProperties: TMQTTConnAckProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Received CONNACK');

  AssignedClientID := StringReplace(DynArrayOfByteToString(AConnAckProperties.AssignedClientIdentifier), #0, '#0', [rfReplaceAll]);
  frmFindSubControlWorkerMain.lbeClientID.Text := AssignedClientID;

  frmFindSubControlWorkerMain.AddToLog('ConnAckFields.EnabledProperties: ' + IntToStr(AConnAckFields.EnabledProperties));
  frmFindSubControlWorkerMain.AddToLog('ConnAckFields.SessionPresentFlag: ' + IntToStr(AConnAckFields.SessionPresentFlag));
  frmFindSubControlWorkerMain.AddToLog('ConnAckFields.ConnectReasonCode: ' + IntToStr(AConnAckFields.ConnectReasonCode));  //should be 0

  frmFindSubControlWorkerMain.AddToLog('SessionExpiryInterval: ' + IntToStr(AConnAckProperties.SessionExpiryInterval));
  frmFindSubControlWorkerMain.AddToLog('ReceiveMaximum: ' + IntToStr(AConnAckProperties.ReceiveMaximum));
  frmFindSubControlWorkerMain.AddToLog('MaximumQoS: ' + IntToStr(AConnAckProperties.MaximumQoS));
  frmFindSubControlWorkerMain.AddToLog('RetainAvailable: ' + IntToStr(AConnAckProperties.RetainAvailable));
  frmFindSubControlWorkerMain.AddToLog('MaximumPacketSize: ' + IntToStr(AConnAckProperties.MaximumPacketSize));
  frmFindSubControlWorkerMain.AddToLog('AssignedClientIdentifier: ' + AssignedClientID);
  frmFindSubControlWorkerMain.AddToLog('TopicAliasMaximum: ' + IntToStr(AConnAckProperties.TopicAliasMaximum));
  frmFindSubControlWorkerMain.AddToLog('ReasonString: ' + StringReplace(DynArrayOfByteToString(AConnAckProperties.ReasonString), #0, '#0', [rfReplaceAll]));

  {$IFDEF EnUserProperty}
    frmFindSubControlWorkerMain.AddToLog('UserProperty: ' + StringReplace(DynOfDynArrayOfByteToString(AConnAckProperties.UserProperty), #0, '#0', [rfReplaceAll]));
  {$ENDIF}

  frmFindSubControlWorkerMain.AddToLog('WildcardSubscriptionAvailable: ' + IntToStr(AConnAckProperties.WildcardSubscriptionAvailable));
  frmFindSubControlWorkerMain.AddToLog('SubscriptionIdentifierAvailable: ' + IntToStr(AConnAckProperties.SubscriptionIdentifierAvailable));
  frmFindSubControlWorkerMain.AddToLog('SharedSubscriptionAvailable: ' + IntToStr(AConnAckProperties.SharedSubscriptionAvailable));
  frmFindSubControlWorkerMain.AddToLog('ServerKeepAlive: ' + IntToStr(AConnAckProperties.ServerKeepAlive));
  frmFindSubControlWorkerMain.AddToLog('ResponseInformation: ' + StringReplace(DynArrayOfByteToString(AConnAckProperties.ResponseInformation), #0, '#0', [rfReplaceAll]));
  frmFindSubControlWorkerMain.AddToLog('ServerReference: ' + StringReplace(DynArrayOfByteToString(AConnAckProperties.ServerReference), #0, '#0', [rfReplaceAll]));
  frmFindSubControlWorkerMain.AddToLog('AuthenticationMethod: ' + StringReplace(DynArrayOfByteToString(AConnAckProperties.AuthenticationMethod), #0, '#0', [rfReplaceAll]));
  frmFindSubControlWorkerMain.AddToLog('AuthenticationData: ' + StringReplace(DynArrayOfByteToString(AConnAckProperties.AuthenticationData), #0, '#0', [rfReplaceAll]));

  frmFindSubControlWorkerMain.AddToLog('');

  ///////////////////////////////////////// when the server returns SessionPresentFlag set to 1, the library resends unacknowledged Publish and PubRel packets.
  //AConnAckFields.SessionPresentFlag := 1;
end;


function HandleOnBeforeSendingMQTT_SUBSCRIBE(ClientInstance: DWord;  //The lower word identifies the client instance
                                             var ASubscribeFields: TMQTTSubscribeFields;
                                             var ASubscribeProperties: TMQTTSubscribeProperties;
                                             ACallbackID: Word): Boolean;
var
  Options, QoS: Byte;
  SubId: Word;
begin
  Options := 0;
  QoS := 2;

  Options := Options or QoS; //bits 1 and 0
  //Bit 2 of the Subscription Options represents the No Local option.  - spec pag 73
  //Bit 3 of the Subscription Options represents the Retain As Published option.  - spec pag 73
  //Bits 4 and 5 of the Subscription Options represent the Retain Handling option.  - spec pag 73
  //Bits 6 and 7 of the Subscription Options byte are reserved for future use. - Must be set to 0.  - spec pag 73

                                                                            //Subscription identifiers are not mandatory (per spec).
  SubId := MQTT_CreateClientToServerSubscriptionIdentifier(ClientInstance); //This function has to be called here, in this handler only. The library does not call this function other than for init purposes.
                                                                            //If SubscriptionIdentifiers are used, then user code should free them when resubscribing or when unsubscribing.
  ASubscribeProperties.SubscriptionIdentifier := SubId;  //For now, the user code should keep track of these identifiers and free them on resubscribing or unsubscribing.
  frmFindSubControlWorkerMain.AddToLog('Subscribing with new SubscriptionIdentifier: ' + IntToStr(SubId));

  Result := FillIn_SubscribePayload(CTopicName_AppToWorker_GetCapabilities, Options, ASubscribeFields.TopicFilters);  //call this again with a different string (i.e. TopicFilter), in order to add it to ASubscribeFields.TopicFilters
  if not Result then
  begin
    frmFindSubControlWorkerMain.AddToLog('HandleOnBeforeSendingMQTT_SUBSCRIBE not enough memory to add TopicFilters.');
    Exit;
  end;

  Result := FillIn_SubscribePayload(CTopicName_AppToWorker_FindSubControl, Options, ASubscribeFields.TopicFilters);  //call this again with a different string (i.e. TopicFilter), in order to add it to ASubscribeFields.TopicFilters
  if not Result then
  begin
    frmFindSubControlWorkerMain.AddToLog('HandleOnBeforeSendingMQTT_SUBSCRIBE not enough memory to add TopicFilters.');
    Exit;
  end;
  //
  //Result := FillIn_SubscribePayload('MoreExtra_' + frmFindSubControlWorkerMain.lbeTopicName.Text, 1, ASubscribeFields.TopicFilters);  //call this again with a different string (i.e. TopicFilter), in order to add it to ASubscribeFields.TopicFilters
  //if not Result then
  //begin
  //  frmFindSubControlWorkerMain.AddToLog('HandleOnBeforeSendingMQTT_SUBSCRIBE not enough memory to add TopicFilters.');
  //  Exit;
  //end;
  //
  //Result := FillIn_SubscribePayload('LastExtra_' + frmFindSubControlWorkerMain.lbeTopicName.Text, 0, ASubscribeFields.TopicFilters);  //call this again with a different string (i.e. TopicFilter), in order to add it to ASubscribeFields.TopicFilters
  //if not Result then
  //begin
  //  frmFindSubControlWorkerMain.AddToLog('HandleOnBeforeSendingMQTT_SUBSCRIBE not enough memory to add TopicFilters.');
  //  Exit;
  //end;

  //Enable SubscriptionIdentifier only if required (allocated above with CreateClientToServerSubscriptionIdentifier) !!!
  //The library initializes EnabledProperties to 0.
  //A subscription is allowed to be made without a SubscriptionIdentifier.
  ASubscribeFields.EnabledProperties := CMQTTSubscribe_EnSubscriptionIdentifier {or CMQTTSubscribe_EnUserProperty};

  frmFindSubControlWorkerMain.AddToLog('Subscribing with PacketIdentifier: ' + IntToStr(ASubscribeFields.PacketIdentifier));
  frmFindSubControlWorkerMain.AddToLog('Subscribing to: ' + StringReplace(DynArrayOfByteToString(ASubscribeFields.TopicFilters), #0, '#0', [rfReplaceAll]));

  frmFindSubControlWorkerMain.AddToLog('');
end;


procedure HandleOnAfterReceivingMQTT_SUBACK(ClientInstance: DWord; var ASubAckFields: TMQTTSubAckFields; var ASubAckProperties: TMQTTSubAckProperties);
var
  i: Integer;
begin
  frmFindSubControlWorkerMain.AddToLog('Received SUBACK');
  //frmFindSubControlWorkerMain.AddToLog('ASubAckFields.IncludeReasonCode: ' + IntToStr(ASubAckFields.IncludeReasonCode));  //not used
  //frmFindSubControlWorkerMain.AddToLog('ASubAckFields.ReasonCode: ' + IntToStr(ASubAckFields.ReasonCode));              //not used
  frmFindSubControlWorkerMain.AddToLog('ASubAckFields.EnabledProperties: ' + IntToStr(ASubAckFields.EnabledProperties));
  frmFindSubControlWorkerMain.AddToLog('ASubAckFields.PacketIdentifier: ' + IntToStr(ASubAckFields.PacketIdentifier));  //This must be the same as sent in SUBSCRIBE packet.

  frmFindSubControlWorkerMain.AddToLog('ASubAckFields.Payload.Len: ' + IntToStr(ASubAckFields.SrcPayload.Len));

  for i := 0 to ASubAckFields.SrcPayload.Len - 1 do         //these are QoS values for each TopicFilter (if ok), or error codes (if not ok).
    frmFindSubControlWorkerMain.AddToLog('ASubAckFields.ReasonCodes[' + IntToStr(i) + ']: ' + IntToStr(ASubAckFields.SrcPayload.Content^[i]));

  frmFindSubControlWorkerMain.AddToLog('ASubAckProperties.ReasonString: ' + StringReplace(DynArrayOfByteToString(ASubAckProperties.ReasonString), #0, '#0', [rfReplaceAll]));

  {$IFDEF EnUserProperty}
    frmFindSubControlWorkerMain.AddToLog('ASubAckProperties.UserProperty: ' + StringReplace(DynOfDynArrayOfByteToString(ASubAckProperties.UserProperty), #0, '#0', [rfReplaceAll]));
  {$ENDIF}

  frmFindSubControlWorkerMain.tmrSubscribe.Enabled := False;

  frmFindSubControlWorkerMain.AddToLog('');
end;


function HandleOnBeforeSendingMQTT_UNSUBSCRIBE(ClientInstance: DWord;  //The lower word identifies the client instance
                                               var AUnsubscribeFields: TMQTTUnsubscribeFields;
                                               var AUnsubscribeProperties: TMQTTUnsubscribeProperties;
                                               ACallbackID: Word): Boolean;
begin
  Result := FillIn_UnsubscribePayload(CTopicName_AppToWorker_GetCapabilities, AUnsubscribeFields.TopicFilters);  //call this again with a different string (i.e. TopicFilter), in order to add it to AUnsubscribeFields.TopicFilters
  if not Result then
  begin
    frmFindSubControlWorkerMain.AddToLog('HandleOnBeforeSendingMQTT_UNSUBSCRIBE not enough memory to add TopicFilters.');
    Exit;
  end;

  Result := FillIn_UnsubscribePayload(CTopicName_AppToWorker_FindSubControl, AUnsubscribeFields.TopicFilters);  //call this again with a different string (i.e. TopicFilter), in order to add it to AUnsubscribeFields.TopicFilters
  if not Result then
  begin
    frmFindSubControlWorkerMain.AddToLog('HandleOnBeforeSendingMQTT_UNSUBSCRIBE not enough memory to add TopicFilters.');
    Exit;
  end;

  frmFindSubControlWorkerMain.AddToLog('Unsubscribing from "' + CTopicName_AppToWorker_GetCapabilities + '" and "' + CTopicName_AppToWorker_FindSubControl + '"...');

  //the user code should call RemoveClientToServerSubscriptionIdentifier to remove the allocate identifier.
end;


procedure HandleOnAfterReceivingMQTT_UNSUBACK(ClientInstance: DWord; var AUnsubAckFields: TMQTTUnsubAckFields; var AUnsubAckProperties: TMQTTUnsubAckProperties);
var
  i: Integer;
begin
  frmFindSubControlWorkerMain.AddToLog('Received UNSUBACK');
  //frmFindSubControlWorkerMain.AddToLog('AUnsubAckFields.IncludeReasonCode: ' + IntToStr(ASubAckFields.IncludeReasonCode));  //not used
  //frmFindSubControlWorkerMain.AddToLog('AUnsubAckFields.ReasonCode: ' + IntToStr(ASubAckFields.ReasonCode));              //not used
  frmFindSubControlWorkerMain.AddToLog('AUnsubAckFields.EnabledProperties: ' + IntToStr(AUnsubAckFields.EnabledProperties));
  frmFindSubControlWorkerMain.AddToLog('AUnsubAckFields.PacketIdentifier: ' + IntToStr(AUnsubAckFields.PacketIdentifier));  //This must be the same as sent in SUBSCRIBE packet.

  frmFindSubControlWorkerMain.AddToLog('AUnsubAckFields.Payload.Len: ' + IntToStr(AUnsubAckFields.SrcPayload.Len));

  for i := 0 to AUnsubAckFields.SrcPayload.Len - 1 do         //these are QoS values for each TopicFilter (if ok), or error codes (if not ok).
    frmFindSubControlWorkerMain.AddToLog('AUnsubAckFields.ReasonCodes[' + IntToStr(i) + ']: ' + IntToStr(AUnsubAckFields.SrcPayload.Content^[i]));

  frmFindSubControlWorkerMain.AddToLog('AUnsubAckProperties.ReasonString: ' + StringReplace(DynArrayOfByteToString(AUnsubAckProperties.ReasonString), #0, '#0', [rfReplaceAll]));

  {$IFDEF EnUserProperty}
    frmFindSubControlWorkerMain.AddToLog('AUnsubAckProperties.UserProperty: ' + StringReplace(DynOfDynArrayOfByteToString(AUnsubAckProperties.UserProperty), #0, '#0', [rfReplaceAll]));
  {$ENDIF}

  frmFindSubControlWorkerMain.AddToLog('');
end;


var
  FindSubControlResponse: string;


//This handler is used when this client publishes a message to broker.
function HandleOnBeforeSendingMQTT_PUBLISH(ClientInstance: DWord;  //The lower word identifies the client instance (the library is able to implement multiple MQTT clients / device). The higher byte can identify the call in user handlers for various events (e.g. TOnBeforeMQTT_CONNECT).
                                           var APublishFields: TMQTTPublishFields;                    //user code has to fill-in this parameter
                                           var APublishProperties: TMQTTPublishProperties;            //user code has to fill-in this parameter
                                           ACallbackID: Word): Boolean;
var
  Msg: string;
  QoS: Byte;
  OS: string;
begin
  Result := True;

  case ACallbackID of
    0:
    begin
      OS := 'Unknown';
      {$IFDEF Windows}
        OS := 'Win';
      {$ENDIF}
      {$IFDEF UNIX}
        OS := 'Lin';
      {$ENDIF}

      Msg := CProtocolParam_Name + '=' + AssignedClientID + #13#10;
      Msg := Msg + CProtocolParam_OS + '=' + OS + #13#10;
      Msg := Msg + CProtocolParam_FileCache + '=' + FastReplace_ReturnTo45(frmFindSubControlWorkerMain.FInMemFS.ListMemFilesWithHashAsString);
    end;

    1:
    begin
      Msg := FindSubControlResponse; //'In work. FindSubControl result.';

    end;

    else
      Msg := 'unknown CallbackID';
  end;

  QoS := (APublishFields.PublishCtrlFlags shr 1) and 3;
  frmFindSubControlWorkerMain.AddToLog('Publishing "' + Msg + '" at QoS = ' + IntToStr(QoS));

  Result := Result and StringToDynArrayOfByte(Msg, APublishFields.ApplicationMessage);

  case ACallbackID of
    0: Result := Result and StringToDynArrayOfByte(CTopicName_WorkerToApp_GetCapabilities, APublishFields.TopicName);
    1: Result := Result and StringToDynArrayOfByte(CTopicName_WorkerToApp_FindSubControl, APublishFields.TopicName);
    else
      Result := Result and StringToDynArrayOfByte(CMQTT_Worker_UnhandledRequest, APublishFields.TopicName);
  end;

  frmFindSubControlWorkerMain.AddToLog('');
  //QoS can be overriden here. If users override QoS in this handler, then a a different PacketIdentifier might be allocated (depending on what is available)
end;


//This handler is used when this client publishes a message to broker and the broker responds with PUBACK.
procedure HandleOnBeforeSendingMQTT_PUBACK(ClientInstance: DWord; var APubAckFields: TMQTTPubAckFields; var APubAckProperties: TMQTTPubAckProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Acknowledging with PUBACK');
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.EnabledProperties: ' + IntToStr(APubAckFields.EnabledProperties));
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.IncludeReasonCode: ' + IntToStr(APubAckFields.IncludeReasonCode));
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.PacketIdentifier: ' + IntToStr(APubAckFields.PacketIdentifier));
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.ReasonCode: ' + IntToStr(APubAckFields.ReasonCode));

  frmFindSubControlWorkerMain.AddToLog('APubAckProperties.ReasonString: ' + StringReplace(DynArrayOfByteToString(APubAckProperties.ReasonString), #0, '#0', [rfReplaceAll]));

  {$IFDEF EnUserProperty}
    frmFindSubControlWorkerMain.AddToLog('APubAckProperties.UserProperty: ' + StringReplace(DynOfDynArrayOfByteToString(APubAckProperties.UserProperty), #0, '#0', [rfReplaceAll]));
  {$ENDIF}

  frmFindSubControlWorkerMain.AddToLog('');
  //This handler can be used to override what is being sent to server as a reply to PUBLISH
end;


procedure HandleOnAfterReceivingMQTT_PUBACK(ClientInstance: DWord; var APubAckFields: TMQTTPubAckFields; var APubAckProperties: TMQTTPubAckProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Received PUBACK');
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.EnabledProperties: ' + IntToStr(APubAckFields.EnabledProperties));
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.IncludeReasonCode: ' + IntToStr(APubAckFields.IncludeReasonCode));
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.PacketIdentifier: ' + IntToStr(APubAckFields.PacketIdentifier));
  frmFindSubControlWorkerMain.AddToLog('APubAckFields.ReasonCode: ' + IntToStr(APubAckFields.ReasonCode));

  frmFindSubControlWorkerMain.AddToLog('APubAckProperties.ReasonString: ' + StringReplace(DynArrayOfByteToString(APubAckProperties.ReasonString), #0, '#0', [rfReplaceAll]));

  {$IFDEF EnUserProperty}
    frmFindSubControlWorkerMain.AddToLog('APubAckProperties.UserProperty: ' + StringReplace(DynOfDynArrayOfByteToString(APubAckProperties.UserProperty), #0, '#0', [rfReplaceAll]));
  {$ENDIF}

  frmFindSubControlWorkerMain.AddToLog('');
end;


function SendFileToUIClickerWithLoc(AContent: TMemoryStream; AFilename, InMemLoc: string): string;
begin
  Result := SendFileToServer('http://127.0.0.1:' + frmFindSubControlWorkerMain.lbeUIClickerPort.Text + '/' +
                                                   InMemLoc + '?' +
                                                   CREParam_FileName + '=' + AFilename,
                             AContent);
end;


function SendFileToUIClicker_SrvInMem(AContent: TMemoryStream; AFilename: string): string;   //used for most files
begin
  Result := SendFileToUIClickerWithLoc(AContent, AFilename, CRECmd_SendFileToServer);
end;


function SendFileToUIClicker_ExtRndInMem(AContent: TMemoryStream; AFilename: string): string;   //used for background
begin
  Result := SendFileToUIClickerWithLoc(AContent, AFilename, CRECmd_SetRenderedFile);
end;


function SendExecuteFindSubControlAction(AActionContent: string): string;
var
  TempFindSubControl: TClkFindControlOptions;
  TempActionOptions: TClkActionOptions;
  ActionContentList: TStringList;
  ConversionResult, UIClickerAddr: string;
  FindSubControlTimeout: Integer;
begin
  ActionContentList := TStringList.Create;
  try
    ActionContentList.Text := StringReplace(AActionContent, '&', #13#10, [rfReplaceAll]);

    FindSubControlTimeout := StrToIntDef(ActionContentList.Values[CPropertyName_ActionTimeout], -2);
    if FindSubControlTimeout = -2 then
    begin
      FindSubControlTimeout := CMinFindSubControlActionTimeout;
      frmFindSubControlWorkerMain.AddToLog('=============== Did not receive a valid action timeout. Setting to minimum: ' + IntToStr(FindSubControlTimeout) + 'ms.');
    end;

    ConversionResult := SetFindControlActionProperties(ActionContentList, True, @frmFindSubControlWorkerMain.AddToLog, TempFindSubControl, TempActionOptions);
    if ConversionResult <> '' then
    begin
      frmFindSubControlWorkerMain.AddToLog('ConversionResult: ' + ConversionResult);
      Result := ConversionResult;
      Exit;
    end;
  finally
    ActionContentList.Free;
  end;

  TempFindSubControl.ImageSource := isFile;
  TempFindSubControl.SourceFileName := CBackgroundFileNameForUIClicker;
  TempFindSubControl.ImageSourceFileNameLocation := isflMem;

  UIClickerAddr := 'http://127.0.0.1:' + frmFindSubControlWorkerMain.lbeUIClickerPort.Text + '/';
  Result := ExecuteFindSubControlAction(UIClickerAddr,
                                        TempFindSubControl,
                                        'Action_' + DateTimeToStr(Now),
                                        FindSubControlTimeout, //The HTTP client has its own timeout, currently hardcoded to 1s for connection and 1h for response.
                                        CREParam_FileLocation_ValueMem,
                                        True);
end;


procedure SaveBackgroundBmpToInMemFS(AContent: TMemoryStream);
var
  Hash, BackgroundFnm: string;
begin
  Hash := ComputeHash(AContent.Memory, AContent.Size);
  BackgroundFnm := 'Background_' + Hash + '.bmp';

  if not frmFindSubControlWorkerMain.FInMemFS.FileExistsInMem(BackgroundFnm) then
    frmFindSubControlWorkerMain.FInMemFS.SaveFileToMem(BackgroundFnm, AContent.Memory, AContent.Size);
end;


procedure AddToLog(AMsg: string);
begin
  frmFindSubControlWorkerMain.AddToLog(AMsg);
end;


procedure HandleOnAfterReceivingMQTT_PUBLISH(ClientInstance: DWord; var APublishFields: TMQTTPublishFields; var APublishProperties: TMQTTPublishProperties);
const
  CImageSourceRawContentParam: string = '&' + CProtocolParam_ImageSourceRawContent + '=';
var
  QoS: Byte;
  ID: Word;
  Topic, s, Msg, TempWorkerSpecificTask: string;
  i: Integer;
  BmpStr: string;
  MemStream, DecompressedStream: TMemoryStream;
  SetVarRequest: TClkSetVarOptions;
  CmdResult: string;
  UsingCompression: Boolean;
  CompressionAlgorithm: string;
  TempArchiveHandlers: TArchiveHandlers;
  MemArchive: TMemArchive;
  tk: QWord;
  ListOfArchiveFiles: TStringList;
  PosImageSourceRawContent: Integer;
  TempFindSubControlResponse: string;
begin
  QoS := (APublishFields.PublishCtrlFlags shr 1) and 3;
  Msg := DynArrayOfByteToString(APublishFields.ApplicationMessage); //StringReplace(DynArrayOfByteToString(APublishFields.ApplicationMessage), #0, '#0', [rfReplaceAll]);
  ID := APublishFields.PacketIdentifier;
  Topic := DynArrayOfByteToString(APublishFields.TopicName); //StringReplace(DynArrayOfByteToString(APublishFields.TopicName), #0, '#0', [rfReplaceAll]);
  TempWorkerSpecificTask := DynArrayOfByteToString(APublishProperties.ContentType);


  frmFindSubControlWorkerMain.AddToLog('Received PUBLISH' + #13#10 +
                                       '  ServerPacketIdentifier: ' + IntToStr(ID) + #13#10 +
                                       '  Msg: ' + Copy(StringReplace(Msg, #0, #1, [rfReplaceAll]), 1, 100) + #13#10 +   //Do not display entire content. It may be a bitmap
                                       '  QoS: ' + IntToStr(QoS) + #13#10 +
                                       '  TopicName: ' + Topic + #13#10 +
                                       '  WorkerSpecificTask: ' + TempWorkerSpecificTask + #13#10 +
                                       '  PublishCtrlFlags: ' + IntToStr(APublishFields.PublishCtrlFlags));

  s := '';
  for i := 0 to APublishProperties.SubscriptionIdentifier.Len - 1 do
    s := s + IntToStr(APublishProperties.SubscriptionIdentifier.Content^[i]) + ', ';
  frmFindSubControlWorkerMain.AddToLog('SubscriptionIdentifier(s): ' + s);

  if Topic = CTopicName_AppToWorker_GetCapabilities then
  begin
    ////////////////////////////////// respond with something  (i.e. call MQTT_PUBLISH)
    if not MQTT_PUBLISH(ClientInstance, 0, QoS) then
      frmFindSubControlWorkerMain.AddToLog('Cannot respond with capabilities');
  end;

  if Topic = CTopicName_AppToWorker_FindSubControl then
  begin
    ////////////////////////////////// respond with something  (i.e. call MQTT_PUBLISH)    //////////////////// start rendering
    frmFindSubControlWorkerMain.AddToLog('Executing FindSubControl');

    PosImageSourceRawContent := Pos(CImageSourceRawContentParam, Msg);
    BmpStr := Copy(Msg, PosImageSourceRawContent + Length(CImageSourceRawContentParam), MaxInt);

    UsingCompression := Copy(Msg, Pos('&' + CProtocolParam_UsingCompression + '=', Msg) + Length('&' + CProtocolParam_UsingCompression + '='), 1) = '1';
    CompressionAlgorithm := Copy(Msg, Pos('&' + CProtocolParam_CompressionAlgorithm + '=', Msg) + Length('&' + CProtocolParam_CompressionAlgorithm + '='), 30);  //assumes the name of the algorithm is not longer than 30
    CompressionAlgorithm := Copy(CompressionAlgorithm, 1, Pos('&', CompressionAlgorithm) - 1);

    Msg := Copy(Msg, 1, PosImageSourceRawContent - 1); //discard archive

    //frmFindSubControlWorkerMain.AddToLog('BmpStr: ' + FastReplace_0To1(BmpStr));
    //frmFindSubControlWorkerMain.AddToLog('=============== UsingCompression: ' + BoolToStr(UsingCompression, 'True', 'False'));
    //frmFindSubControlWorkerMain.AddToLog('=============== CompressionAlgorithm: ' + CompressionAlgorithm);

    MemStream := TMemoryStream.Create;
    DecompressedStream := TMemoryStream.Create;
    try
      MemStream.SetSize(Length(BmpStr));
      MemStream.Write(BmpStr[1], Length(BmpStr));
      MemStream.Position := 0;

      MemArchive := TMemArchive.Create;
      TempArchiveHandlers := TArchiveHandlers.Create;
      try
        TempArchiveHandlers.OnAddToLogNoObj := @AddToLog;

        MemArchive.OnCompress := @TempArchiveHandlers.HandleOnCompress;
        MemArchive.OnDecompress := @TempArchiveHandlers.HandleOnDecompress;
        MemArchive.OnComputeArchiveHash := @TempArchiveHandlers.HandleOnComputeArchiveHash;

        if UsingCompression then
        begin
          MemArchive.CompressionLevel := 9;
          TempArchiveHandlers.CompressionAlgorithm := CompressionAlgorithmsStrToType(CompressionAlgorithm);
        end
        else
          MemArchive.CompressionLevel := 0;

        try
          tk := GetTickCount64;
          MemArchive.OpenArchive(MemStream, False);
          tk := GetTickCount64 - tk;
          try
            MemArchive.ExtractToStream(CBackgroundFileNameInArchive, DecompressedStream);
            AddToLog('Decompressed archive in ' + FloatToStrF(tk / 1000, ffNumber, 15, 5) + 's.  Compressed size: ' + IntToStr(MemStream.Size) + '  Background decompressed size: ' + IntToStr(DecompressedStream.Size));

            SaveBackgroundBmpToInMemFS(DecompressedStream);

            DecompressedStream.Position := 0;
            frmFindSubControlWorkerMain.imgFindSubControlBackground.Picture.Bitmap.LoadFromStream(DecompressedStream);

            CmdResult := SendFileToUIClicker_ExtRndInMem(DecompressedStream, CBackgroundFileNameForUIClicker);
            frmFindSubControlWorkerMain.AddToLog('Sending "' + CBackgroundFileNameInArchive + '" to UIClicker. Response: ' + CmdResult);

            ListOfArchiveFiles := TStringList.Create;
            try
              MemArchive.GetListOfFiles(ListOfArchiveFiles);
              for i := 0 to ListOfArchiveFiles.Count - 1 do
                if ListOfArchiveFiles.Strings[i] <> CBackgroundFileNameInArchive then
                begin
                  DecompressedStream.Clear;
                  MemArchive.ExtractToStream(ListOfArchiveFiles.Strings[i], DecompressedStream);
                  SaveBackgroundBmpToInMemFS(DecompressedStream);

                  /////////////////////////////////////////////////////// verify cache here

                  CmdResult := SendFileToUIClicker_SrvInMem(DecompressedStream, ListOfArchiveFiles.Strings[i]);
                  frmFindSubControlWorkerMain.AddToLog('Sending "' + ListOfArchiveFiles.Strings[i] + '" to UIClicker. Response: ' + CmdResult);
                end;
            finally
              ListOfArchiveFiles.Free;
            end;
          finally
            MemArchive.CloseArchive;
          end;
        except
          on E: Exception do
          begin
            frmFindSubControlWorkerMain.AddToLog('Error working with received archive: "' + E.Message + '"  MemStream.Size = ' + IntToStr(MemStream.Size));
            /////////////////// Set result to False
          end;
        end;
      finally
        TempArchiveHandlers.Free;
        MemArchive.Free;
      end;
    finally
      MemStream.Free;
      DecompressedStream.Free;
    end;

    //call CRECmd_ExecuteFindSubControlAction   (later, add support for calling CRECmd_ExecutePlugin)
    frmFindSubControlWorkerMain.AddToLog('Sending FindSubControl request...');

    TempFindSubControlResponse := SendExecuteFindSubControlAction(Msg);
    frmFindSubControlWorkerMain.AddToLog('FindSubControl result: ' + #13#10 + FastReplace_87ToReturn(TempFindSubControlResponse));

    FindSubControlResponse := TempFindSubControlResponse;
    MQTT_PUBLISH(ClientInstance, 1, QoS);
    if not MQTT_PUBLISH(0, 0, QoS) then
      frmFindSubControlWorkerMain.AddToLog('Cannot respond with capabilities');

    //call CRECmd_GetResultedDebugImage
  end;

  frmFindSubControlWorkerMain.AddToLog('');
end;


procedure HandleOnBeforeSending_MQTT_PUBREC(ClientInstance: DWord; var ATempPubRecFields: TMQTTPubRecFields; var ATempPubRecProperties: TMQTTPubRecProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Acknowledging with PUBREC for ServerPacketID: ' + IntToStr(ATempPubRecFields.PacketIdentifier));
end;


procedure HandleOnAfterReceiving_MQTT_PUBREC(ClientInstance: DWord; var ATempPubRecFields: TMQTTPubRecFields; var ATempPubRecProperties: TMQTTPubRecProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Received PUBREC for PacketID: ' + IntToStr(ATempPubRecFields.PacketIdentifier));
end;


//Sending PUBREL after the PUBREC response from server, after the client has sent a PUBLISH packet with QoS=2.
procedure HandleOnBeforeSending_MQTT_PUBREL(ClientInstance: DWord; var ATempPubRelFields: TMQTTPubRelFields; var ATempPubRelProperties: TMQTTPubRelProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Acknowledging with PUBREL for PacketID: ' + IntToStr(ATempPubRelFields.PacketIdentifier));
end;


procedure HandleOnAfterReceiving_MQTT_PUBREL(ClientInstance: DWord; var ATempPubRelFields: TMQTTPubRelFields; var ATempPubRelProperties: TMQTTPubRelProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Received PUBREL for ServerPacketID: ' + IntToStr(ATempPubRelFields.PacketIdentifier));
end;


procedure HandleOnBeforeSending_MQTT_PUBCOMP(ClientInstance: DWord; var ATempPubCompFields: TMQTTPubCompFields; var ATempPubCompProperties: TMQTTPubCompProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Acknowledging with PUBCOMP for PacketID: ' + IntToStr(ATempPubCompFields.PacketIdentifier));
end;


procedure HandleOnAfterReceiving_MQTT_PUBCOMP(ClientInstance: DWord; var ATempPubCompFields: TMQTTPubCompFields; var ATempPubCompProperties: TMQTTPubCompProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Received PUBCOMP for ServerPacketID: ' + IntToStr(ATempPubCompFields.PacketIdentifier));
end;


procedure HandleOnAfterReceivingMQTT_PINGRESP(ClientInstance: DWord);
begin
  frmFindSubControlWorkerMain.AddToLog('Received PINGRESP');
end;


procedure HandleOnBeforeSendingMQTT_DISCONNECT(ClientInstance: DWord;  //The lower word identifies the client instance
                                               var ADisconnectFields: TMQTTDisconnectFields;
                                               var ADisconnectProperties: TMQTTDisconnectProperties;
                                               ACallbackID: Word);
begin
  frmFindSubControlWorkerMain.AddToLog('Sending DISCONNECT');
  //ADisconnectFields.EnabledProperties := CMQTTDisconnect_EnSessionExpiryInterval;   //uncomment if needed
  //ADisconnectProperties.SessionExpiryInterval := 1;

  //From spec, pag 89:
  //If the Session Expiry Interval is absent, the Session Expiry Interval in the CONNECT packet is used.
  //If the Session Expiry Interval in the CONNECT packet was zero, then it is a Protocol Error to set a non-
  //zero Session Expiry Interval in the DISCONNECT packet sent by the Client.

  //From spec, pag 89:
  //After sending a DISCONNECT packet the sender
  //  MUST NOT send any more MQTT Control Packets on that Network Connection
  //  MUST close the Network Connection
end;


procedure HandleOnAfterReceivingMQTT_DISCONNECT(ClientInstance: DWord;  //The lower word identifies the client instance
                                                var ADisconnectFields: TMQTTDisconnectFields;
                                                var ADisconnectProperties: TMQTTDisconnectProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Received DISCONNECT');

  frmFindSubControlWorkerMain.AddToLog('ADisconnectFields.EnabledProperties' + IntToStr(ADisconnectFields.EnabledProperties));
  frmFindSubControlWorkerMain.AddToLog('ADisconnectFields.DisconnectReasonCode' + IntToStr(ADisconnectFields.DisconnectReasonCode));

  frmFindSubControlWorkerMain.AddToLog('ADisconnectProperties.SessionExpiryInterval' + IntToStr(ADisconnectProperties.SessionExpiryInterval));
  frmFindSubControlWorkerMain.AddToLog('ADisconnectProperties.ReasonString' + StringReplace(DynArrayOfByteToString(ADisconnectProperties.ReasonString), #0, '#0', [rfReplaceAll]));
  frmFindSubControlWorkerMain.AddToLog('ADisconnectProperties.ServerReference' + StringReplace(DynArrayOfByteToString(ADisconnectProperties.ServerReference), #0, '#0', [rfReplaceAll]));

  {$IFDEF EnUserProperty}
    frmFindSubControlWorkerMain.AddToLog('ADisconnectProperties.UserProperty' + StringReplace(DynOfDynArrayOfByteToString(ADisconnectProperties.UserProperty), #0, '#0', [rfReplaceAll]));
  {$ENDIF}
end;


procedure HandleOnBeforeSendingMQTT_AUTH(ClientInstance: DWord;  //The lower word identifies the client instance
                                         var AAuthFields: TMQTTAuthFields;
                                         var AAuthProperties: TMQTTAuthProperties;
                                         ACallbackID: Word);
begin
  frmFindSubControlWorkerMain.AddToLog('Sending AUTH');
  AAuthFields.AuthReasonCode := $19; //Example: reauth   - see spec, pag 108.

  StringToDynArrayOfByte('SCRAM-SHA-1', AAuthProperties.AuthenticationMethod);       //some example from spec, pag 108
  StringToDynArrayOfByte('client-second-data', AAuthProperties.AuthenticationData);   //some modified example from spec, pag 108
end;


procedure HandleOnAfterReceivingMQTT_AUTH(ClientInstance: DWord;  //The lower word identifies the client instance
                                          var AAuthFields: TMQTTAuthFields;
                                          var AAuthProperties: TMQTTAuthProperties);
begin
  frmFindSubControlWorkerMain.AddToLog('Received AUTH');

  frmFindSubControlWorkerMain.AddToLog('AAuthFields.EnabledProperties' + IntToStr(AAuthFields.EnabledProperties));
  frmFindSubControlWorkerMain.AddToLog('AAuthFields.AuthReasonCode' + IntToStr(AAuthFields.AuthReasonCode));

  frmFindSubControlWorkerMain.AddToLog('AAuthProperties.ReasonString' + StringReplace(DynArrayOfByteToString(AAuthProperties.ReasonString), #0, '#0', [rfReplaceAll]));
  frmFindSubControlWorkerMain.AddToLog('AAuthProperties.ServerReference' + StringReplace(DynArrayOfByteToString(AAuthProperties.AuthenticationMethod), #0, '#0', [rfReplaceAll]));
  frmFindSubControlWorkerMain.AddToLog('AAuthProperties.ServerReference' + StringReplace(DynArrayOfByteToString(AAuthProperties.AuthenticationData), #0, '#0', [rfReplaceAll]));

  {$IFDEF EnUserProperty}
    frmFindSubControlWorkerMain.AddToLog('AAuthProperties.UserProperty' + StringReplace(DynOfDynArrayOfByteToString(AAuthProperties.UserProperty), #0, '#0', [rfReplaceAll]));
  {$ENDIF}
end;

{ TfrmFindSubControlWorkerMain }


procedure TfrmFindSubControlWorkerMain.AddToLog(AMsg: string);  //thread safe
begin
  FLoggingFIFO.Put(AMsg);
end;


procedure TfrmFindSubControlWorkerMain.SyncReceivedBuffer(var AReadBuf: TDynArrayOfByte); //thread safe
begin
  FRecBufFIFO.Put(DynArrayOfByteToString(AReadBuf));
end;


procedure TfrmFindSubControlWorkerMain.ProcessReceivedBuffer;  //called by a timer, to process received data
var
  TempReadBuf: TDynArrayOfByte;
  NewData: string;
begin
  if FRecBufFIFO.Pop(NewData) then
  begin
    //AddToLog('==================Received: ' + StringReplace(NewData, #0, #1, [rfReplaceAll]));
    InitDynArrayToEmpty(TempReadBuf);
    try
      if StringToDynArrayOfByte(NewData, TempReadBuf) then
      begin
        MQTT_PutReceivedBufferToMQTTLib(0, TempReadBuf);
        MQTT_Process(0);
      end
      else
        AddToLog('Out of memory in ProcessReceivedBuffer.');
    finally
      FreeDynArray(TempReadBuf);
    end;
  end;
end;


procedure TfrmFindSubControlWorkerMain.SendString(AString: string);
var
  StrBytes: TIdBytes; //this is array of Byte;
  LenStr: Word;
begin
  LenStr := Length(AString);
  SetLength(StrBytes, LenStr + 2);

  StrBytes[0] := Hi(LenStr);
  StrBytes[1] := Lo(LenStr);

  Move(AString, StrBytes[2], LenStr);

  IdTCPClient1.IOHandler.Write(StrBytes);
end;


procedure TfrmFindSubControlWorkerMain.SendDynArrayOfByte(AArr: TDynArrayOfByte);
var
  TempArr: TIdBytes;
begin
  SetLength(TempArr, AArr.Len);
  Move(AArr.Content^, TempArr[0], AArr.Len);
  IdTCPClient1.IOHandler.Write(TempArr);
end;


procedure TfrmFindSubControlWorkerMain.LogDynArrayOfByte(var AArr: TDynArrayOfByte; ADisplayName: string = '');
var
  i: Integer;
  s: string;
begin
  s := ADisplayName + '  Len: ' + IntToStr(AArr.Len) + '  Data: ';
  for i := 0 to AArr.Len - 1 do
    //s := s + IntToHex(AArr.Content^[i], 2) + ' ';
    s := s + IntToStr(AArr.Content^[i]) + ' ';

  AddToLog(s);
end;


procedure TfrmFindSubControlWorkerMain.InitHandlers;
begin
  {$IFDEF IsDesktop}
    OnMQTTError^ := @HandleOnMQTTError;
    OnSendMQTT_Packet^ := @HandleOnSend_MQTT_Packet;
    OnBeforeMQTT_CONNECT^ := @HandleOnBeforeMQTT_CONNECT;
    OnAfterMQTT_CONNACK^ := @HandleOnAfterMQTT_CONNACK;
    OnBeforeSendingMQTT_PUBLISH^ := @HandleOnBeforeSendingMQTT_PUBLISH;
    OnBeforeSendingMQTT_PUBACK^ := @HandleOnBeforeSendingMQTT_PUBACK;
    OnAfterReceivingMQTT_PUBACK^ := @HandleOnAfterReceivingMQTT_PUBACK;
    OnAfterReceivingMQTT_PUBLISH^ := @HandleOnAfterReceivingMQTT_PUBLISH;
    OnBeforeSendingMQTT_PUBREC^ := @HandleOnBeforeSending_MQTT_PUBREC;
    OnAfterReceivingMQTT_PUBREC^ := @HandleOnAfterReceiving_MQTT_PUBREC;
    OnBeforeSendingMQTT_PUBREL^ := @HandleOnBeforeSending_MQTT_PUBREL;
    OnAfterReceivingMQTT_PUBREL^ := @HandleOnAfterReceiving_MQTT_PUBREL;
    OnBeforeSendingMQTT_PUBCOMP^ := @HandleOnBeforeSending_MQTT_PUBCOMP;
    OnAfterReceivingMQTT_PUBCOMP^ := @HandleOnAfterReceiving_MQTT_PUBCOMP;
    OnBeforeSendingMQTT_SUBSCRIBE^ := @HandleOnBeforeSendingMQTT_SUBSCRIBE;
    OnAfterReceivingMQTT_SUBACK^ := @HandleOnAfterReceivingMQTT_SUBACK;
    OnBeforeSendingMQTT_UNSUBSCRIBE^ := @HandleOnBeforeSendingMQTT_UNSUBSCRIBE;
    OnAfterReceivingMQTT_UNSUBACK^ := @HandleOnAfterReceivingMQTT_UNSUBACK;
    OnAfterReceivingMQTT_PINGRESP^ := @HandleOnAfterReceivingMQTT_PINGRESP;
    OnBeforeSendingMQTT_DISCONNECT^ := @HandleOnBeforeSendingMQTT_DISCONNECT;
    OnAfterReceivingMQTT_DISCONNECT^ := @HandleOnAfterReceivingMQTT_DISCONNECT;
    OnBeforeSendingMQTT_AUTH^ := @HandleOnBeforeSendingMQTT_AUTH;
    OnAfterReceivingMQTT_AUTH^ := @HandleOnAfterReceivingMQTT_AUTH;
  {$ELSE}
    OnMQTTError := @HandleOnMQTTError;
    OnSendMQTT_Packet := @HandleOnSend_MQTT_Packet;
    OnBeforeMQTT_CONNECT := @HandleOnBeforeMQTT_CONNECT;
    OnAfterMQTT_CONNACK := @HandleOnAfterMQTT_CONNACK;
    OnBeforeSendingMQTT_PUBLISH := @HandleOnBeforeSendingMQTT_PUBLISH;
    OnBeforeSendingMQTT_PUBACK := @HandleOnBeforeSendingMQTT_PUBACK;
    OnAfterReceivingMQTT_PUBACK := @HandleOnAfterReceivingMQTT_PUBACK;
    OnAfterReceivingMQTT_PUBLISH := @HandleOnAfterReceivingMQTT_PUBLISH;
    OnBeforeSendingMQTT_PUBREC := @HandleOnBeforeSending_MQTT_PUBREC;
    OnAfterReceivingMQTT_PUBREC := @HandleOnAfterReceiving_MQTT_PUBREC;
    OnBeforeSendingMQTT_PUBREL := @HandleOnBeforeSending_MQTT_PUBREL;
    OnAfterReceivingMQTT_PUBREL := @HandleOnAfterReceiving_MQTT_PUBREL;
    OnBeforeSendingMQTT_PUBCOMP := @HandleOnBeforeSending_MQTT_PUBCOMP;
    OnAfterReceivingMQTT_PUBCOMP := @HandleOnAfterReceiving_MQTT_PUBCOMP;
    OnBeforeSendingMQTT_SUBSCRIBE := @HandleOnBeforeSendingMQTT_SUBSCRIBE;
    OnAfterReceivingMQTT_SUBACK := @HandleOnAfterReceivingMQTT_SUBACK;
    OnBeforeSendingMQTT_UNSUBSCRIBE := @HandleOnBeforeSendingMQTT_UNSUBSCRIBE;
    OnAfterReceivingMQTT_UNSUBACK := @HandleOnAfterReceivingMQTT_UNSUBACK;
    OnAfterReceivingMQTT_PINGRESP := @HandleOnAfterReceivingMQTT_PINGRESP;
    OnBeforeSendingMQTT_DISCONNECT := @HandleOnBeforeSendingMQTT_DISCONNECT;
    OnAfterReceivingMQTT_DISCONNECT := @HandleOnAfterReceivingMQTT_DISCONNECT;
    OnBeforeSendingMQTT_AUTH := @HandleOnBeforeSendingMQTT_AUTH;
    OnAfterReceivingMQTT_AUTH := @HandleOnAfterReceivingMQTT_AUTH;
  {$ENDIF}
end;


procedure TfrmFindSubControlWorkerMain.SendPacketToServer(ClientInstance: DWord);
var
  BufferPointer: PMQTTBuffer;
  Err: Word;
begin
  BufferPointer := MQTT_GetClientToServerBuffer(ClientInstance, Err){$IFnDEF SingleOutputBuffer}^.Content^[0]{$ENDIF};
  SendDynArrayOfByte(BufferPointer^);

  {$IFnDEF SingleOutputBuffer}
    if not MQTT_RemovePacketFromClientToServerBuffer(ClientInstance) then
      AddToLog('Can''t remove latest packet from send buffer.');
  {$ELSE}
    raise Exception.Create('MQTT_RemovePacketFromClientToServerBuffer not implemented for SingleOutputBuffer.');
  {$ENDIF}
end;


type
  TMQTTReceiveThread = class(TThread)
  private
    procedure AddToLog(s: string);
  protected
    procedure Execute; override;
  end;


procedure TMQTTReceiveThread.AddToLog(s: string);
begin
  frmFindSubControlWorkerMain.AddToLog(s);
end;


procedure TMQTTReceiveThread.Execute;
var
  TempReadBuf, ExactPacket: TDynArrayOfByte;
  //ReadCount: Integer;
  TempByte: Byte;
  PacketName: string;
  PacketSize: DWord;
  LoggedDisconnection: Boolean;
  TempArr: TIdBytes;
  SuccessfullyDecoded: Boolean;
  ProcessBufferLengthResult: Word;
begin
  try
    //ReadCount := 0;
    InitDynArrayToEmpty(TempReadBuf);

    try
      LoggedDisconnection := False;
      repeat
        //try
        //  TempByte := frmFindSubControlWorkerMain.IdTCPClient1.IOHandler.ReadByte;
        //  if not AddByteToDynArray(TempByte, TempReadBuf) then
        //  begin
        //    HandleOnMQTTError(0, CMQTT_UserError, CMQTT_UNDEFINED);
        //    AddToLog('Cannot allocate buffer when reading. TempReadBuf.Len = ' + IntToStr(TempReadBuf.Len));
        //    MessageBoxFunction('Cannot allocate buffer when reading.', 'th_', 0);
        //    FreeDynArray(TempReadBuf);
        //  end;
        //except
        //  on E: Exception do      ////////////////// ToDo: switch to EIdReadTimeout
        //  begin
        //    if (E.Message = 'Read timed out.') and (TempReadBuf.Len > 0) then
        //    begin
        //      MQTTPacketToString(TempReadBuf.Content^[0], PacketName);
        //      AddToLog('done receiving packet: ' + E.Message + {'   ReadCount: ' + IntToStr(ReadCount) +} '   E.ClassName: ' + E.ClassName);
        //      AddToLog('Buffer size: ' + IntToStr(TempReadBuf.Len) + '  Packet header: $' + IntToHex(TempReadBuf.Content^[0]) + ' (' + PacketName + ')');
        //
        //      frmFindSubControlWorkerMain.SyncReceivedBuffer(TempReadBuf);
        //
        //      FreeDynArray(TempReadBuf);
        //      //ReadCount := 0; //reset for next packet
        //    end
        //    else
        //      if E.Message = 'Connection Closed Gracefully.' then
        //        if not LoggedDisconnection then
        //        begin
        //          LoggedDisconnection := True;
        //          AddToLog('Disconnected from server. Cannot receive more data. Ex: ' + E.Message);
        //        end;
        //
        //    Sleep(1);
        //  end;
        //end;


        try
          TempByte := frmFindSubControlWorkerMain.IdTCPClient1.IOHandler.ReadByte;
          if not AddByteToDynArray(TempByte, TempReadBuf) then
          begin
            HandleOnMQTTError(0, CMQTT_UserError, CMQTT_UNDEFINED);
            AddToLog('Cannot allocate buffer when reading. TempReadBuf.Len = ' + IntToStr(TempReadBuf.Len));
            MessageBoxFunction('Cannot allocate buffer when reading.', 'th_', 0);
            FreeDynArray(TempReadBuf);
          end
          else
          begin
            SuccessfullyDecoded := True;                                         //PacketSize should be the expected size, which can be greater than TempReadBuf.Len
            ProcessBufferLengthResult := MQTT_ProcessBufferLength(TempReadBuf, PacketSize);

            //AddToLog('----- PacketSize: ' + IntToStr(PacketSize) + '  Len: ' + IntToStr(TempReadBuf.Len) + '  buffer: ' + FastReplace_0To1(Copy(DynArrayOfByteToString(TempReadBuf), 1, 30)));

            if ProcessBufferLengthResult <> CMQTTDecoderNoErr then
            begin
              SuccessfullyDecoded := False;

              if (ProcessBufferLengthResult = CMQTTDecoderIncompleteBuffer) and (PacketSize > 0) then  //PacketSize is successfully decoded, but the packet is incomplete
              begin
                //to get a complete packet, the number of bytes to be read next is PacketSize - TempReadBuf.Len.
                frmFindSubControlWorkerMain.IdTCPClient1.IOHandler.ReadTimeout := 10;

                SetLength(TempArr, 0);
                frmFindSubControlWorkerMain.IdTCPClient1.IOHandler.ReadBytes(TempArr, PacketSize - TempReadBuf.Len);

                if Length(TempArr) > 0 then //it should be >0, otherwise there should be a read timeout exception
                begin
                  if not AddBufferToDynArrayOfByte(@TempArr[0], Length(TempArr), TempReadBuf) then
                  begin
                    AddToLog('Out of memory on allocating TempReadBuf, for multiple bytes.');
                    MessageBoxFunction('Cannot allocate buffer when reading multiple bytes.', 'th_', 0);
                    FreeDynArray(TempReadBuf);
                  end
                  else
                  begin
                    SetLength(TempArr, 0);
                    ProcessBufferLengthResult := MQTT_ProcessBufferLength(TempReadBuf, PacketSize);
                    SuccessfullyDecoded := ProcessBufferLengthResult = CMQTTDecoderNoErr;
                  end;
                end;

                frmFindSubControlWorkerMain.IdTCPClient1.IOHandler.ReadTimeout := 10; //restore timeout, in case the above is increased
              end;
            end;

            if SuccessfullyDecoded then
            begin
              MQTTPacketToString(TempReadBuf.Content^[0], PacketName);
              AddToLog('done receiving packet');
              AddToLog('Buffer size: ' + IntToStr(TempReadBuf.Len) + '  Packet header: $' + IntToHex(TempReadBuf.Content^[0]) + ' (' + PacketName + ')');

              if PacketSize <> TempReadBuf.Len then
              begin
                if CopyFromDynArray(ExactPacket, TempReadBuf, 0, PacketSize) then
                begin
                  frmFindSubControlWorkerMain.SyncReceivedBuffer(ExactPacket);
                  FreeDynArray(ExactPacket);
                  if not RemoveStartBytesFromDynArray(PacketSize, TempReadBuf) then
                    AddToLog('Cannot remove processed packet from TempReadBuf. Packet type: '+ PacketName);
                end
                else
                  AddToLog('Out of memory on allocating ExactPacket.');
              end
              else
              begin
                frmFindSubControlWorkerMain.SyncReceivedBuffer(TempReadBuf);   //MQTT_Process returns an error for unknown and incomplete packets
                FreeDynArray(TempReadBuf);   //freed here, only when a valid packet is formed
              end;

              Sleep(1);
            end; //SuccessfullyDecoded
          end;
        except
        end;

        //Inc(ReadCount);
      until Terminated;
    finally
      AddToLog('Thread done..');
    end;
  except
    on E: Exception do
      AddToLog('Th ex: ' + E.Message);
  end;
end;


var
  Th: TMQTTReceiveThread;


procedure TfrmFindSubControlWorkerMain.FormCreate(Sender: TObject);
begin
  Th := nil;
  FLoggingFIFO := TPollingFIFO.Create;
  FRecBufFIFO := TPollingFIFO.Create;
  FInMemFS := TInMemFileSystem.Create;

  tmrStartup.Enabled := True;
end;


procedure TfrmFindSubControlWorkerMain.FormClose(Sender: TObject;
  var CloseAction: TCloseAction);
var
  tk: QWord;
  ClientToServerBuf: {$IFDEF SingleOutputBuffer} PMQTTBuffer; {$ELSE} PMQTTMultiBuffer; {$ENDIF}
  Err: Word;
begin
  try
    if not MQTT_DISCONNECT(0, 0) then
    begin
      AddToLog('Can''t prepare MQTTDisconnect packet.');
      Exit;
    end;

    tk := GetTickCount64;
    repeat
      ClientToServerBuf := MQTT_GetClientToServerBuffer(0, Err);
      Application.ProcessMessages;
      Sleep(10);
    until (GetTickCount64 - tk > 1500) or ((ClientToServerBuf <> nil) and (ClientToServerBuf^.Len = 0));

    if Th <> nil then
    begin
      Th.Terminate;
      tk := GetTickCount64;
      repeat
        Application.ProcessMessages;
        Sleep(10);
      until (GetTickCount64 - tk > 1500) or Th.Terminated;
      FreeAndNil(Th);
    end;

    IdTCPClient1.Disconnect(False);
  finally
    MQTT_DestroyClient(0);
  end;
end;


procedure TfrmFindSubControlWorkerMain.chkExtServerActiveChange(Sender: TObject);
var
  s: string;
begin
  if chkExtServerActive.Checked then
  begin
    try
      IdHTTPServer1.DefaultPort := StrToIntDef(lbeExtServerPort.Text, 43444);
      IdHTTPServer1.KeepAlive := chkExtServerKeepAlive.Checked;
      IdHTTPServer1.Active := True;

      s := 'Server is listening on port ' + IntToStr(IdHTTPServer1.DefaultPort);

      lblServerInfo.Caption := s;
      lblServerInfo.Font.Color := clGreen;
      lblServerInfo.Hint := '';
    except
      on E: Exception do
      begin
        lblServerInfo.Caption := E.Message;
        lblServerInfo.Font.Color := $000000BB;

        if E.Message = 'Could not bind socket.' then
        begin
          lblServerInfo.Caption := lblServerInfo.Caption + '  (hover for hint)';
          lblServerInfo.Hint := 'Make sure there is no other instance of UIClicker or other application listening on the port.';
          lblServerInfo.Hint := lblServerInfo.Hint + #13#10 + 'If there is another application, started by UIClicker in server mode, with inherited handles, it may keep the socket in use.';
        end;
      end;
    end;
  end
  else
  begin
    IdHTTPServer1.Active := False;
    lblServerInfo.Caption := 'Server module is inactive';
    lblServerInfo.Font.Color := clGray;
    lblServerInfo.Hint := '';
  end;
end;


procedure TfrmFindSubControlWorkerMain.btnDisconnectClick(Sender: TObject);
var
  tk: QWord;
  ClientToServerBuf: {$IFDEF SingleOutputBuffer} PMQTTBuffer; {$ELSE} PMQTTMultiBuffer; {$ENDIF}
  Err: Word;
begin
  //if not MQTT_DISCONNECT(0, 0) then
  //begin
  //  AddToLog('Can''t prepare MQTTDisconnect packet.');
  //  Exit;
  //end;

  //try
  //  tk := GetTickCount64;
  //  repeat
  //    ClientToServerBuf := MQTT_GetClientToServerBuffer(0, Err);
  //    Application.ProcessMessages;
  //    Sleep(10);
  //  until (GetTickCount64 - tk > 1500) or ((ClientToServerBuf <> nil) and (ClientToServerBuf^.Len = 0));
  //except
  //end;

  tmrProcessRecData.Enabled := False;
  tmrProcessLog.Enabled := False;
  Th.Terminate;
  tk := GetTickCount64;
  repeat
    Application.ProcessMessages;
    Sleep(10);
  until (GetTickCount64 - tk > 1500) or Th.Terminated;
  FreeAndNil(Th);

  IdTCPClient1.Disconnect(False);
end;


procedure TfrmFindSubControlWorkerMain.FormDestroy(Sender: TObject);
begin
  FreeAndNil(FLoggingFIFO);
  FreeAndNil(FRecBufFIFO);
  FreeAndNil(Th);
  MQTT_Done;

  FreeAndNil(FInMemFS);
end;


const
  CRECmd_GetImage = 'GetImage';
  CRECmd_Dummy = 'Dummy';


procedure GenerateErrBmp(AFnm: string; ADestStream: TStream);
var
  Bmp: TBitmap;
  Err: string;
  WH: TSize;
begin
  Bmp := TBitmap.Create;
  try
    Err := 'File not found in rendering server: ' + AFnm;
    Bmp.PixelFormat := pf24bit;
    Bmp.Canvas.Font.Size := 10;
    Bmp.Canvas.Font.Color := clYellow;
    Bmp.Canvas.Brush.Color := clBlack;
    WH := Bmp.Canvas.TextExtent(Err);

    Bmp.Width := WH.Width + 10;
    Bmp.Height := WH.Height + 10;
    Bmp.Canvas.TextOut(5, 5, Err);

    Bmp.SaveToStream(ADestStream);
  finally
    Bmp.Free;
  end;
end;


//procedure LocalLoadFileFromMemToStream(AFnm: string; AInMemFS: TInMemFileSystem; ADestStream: TStream);
//begin
//  AInMemFS.LoadFileFromMemToStream(AFnm, ADestStream);
//end;


procedure TfrmFindSubControlWorkerMain.IdHTTPServer1CommandGet(
  AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
  AResponseInfo: TIdHTTPResponseInfo);
var
  Cmd: string;
  s: string;
  Fnm: string;
begin
  Cmd := ARequestInfo.Document;

  AResponseInfo.ContentType := 'text/plain'; // 'text/html';  default type

  if Cmd = '/' + CRECmd_Dummy then
  begin
    AResponseInfo.ContentText := '';  //maybe not needed
    AResponseInfo.ContentType := 'text/html';

    if AResponseInfo.ContentStream = nil then
      AResponseInfo.ContentStream := TMemoryStream.Create;

    s := 'Dummy';
    AResponseInfo.ContentStream.Write(s[1], Length(s));
    Exit;
  end;

  if Cmd = '/' + CRECmd_GetImage then
  begin
    AResponseInfo.ContentText := '';

    AResponseInfo.ContentType := 'image/bmp'; //'application/octet-stream';
    AResponseInfo.ContentDisposition := 'inline'; //display it in browser
    AResponseInfo.CharSet := 'US-ASCII';  //this is actually required, to prevent converting ASCII characters from 128-255 to '?'

    AResponseInfo.ContentStream := TMemoryStream.Create;
    try
      Fnm := ARequestInfo.Params.Values['FileName'];
      if FInMemFS.FileExistsInMem(Fnm) then
        FInMemFS.LoadFileFromMemToStream(Fnm, TMemoryStream(AResponseInfo.ContentStream))   ///////////////////// not sure about this typecasting
      else
        GenerateErrBmp(Fnm, AResponseInfo.ContentStream);

      AResponseInfo.ContentLength := AResponseInfo.ContentStream.Size;

      AResponseInfo.WriteHeader;
      AResponseInfo.WriteContent;
    finally
      AResponseInfo.ContentStream.Free;
      AResponseInfo.ContentStream := nil;
    end;

    Exit; //useful if there are other commands after this
  end;
end;


procedure TfrmFindSubControlWorkerMain.IdHTTPServer1Connect(AContext: TIdContext);
begin
  AContext.Connection.Socket.ReadTimeout := 3600000;   //if no bytes are received in 1h, then close the connection
end;


procedure TfrmFindSubControlWorkerMain.IdHTTPServer1Exception(
  AContext: TIdContext; AException: Exception);
begin
  try
    if AException.Message <> 'Connection Closed Gracefully.' then
      //AddToLogFromThread('Server exception: ' + AException.Message);
  except
  end;
end;


procedure TfrmFindSubControlWorkerMain.tmrConnectTimer(Sender: TObject);
var
  tk: QWord;
begin
  IdTCPClient1.OnConnected := @HandleClientOnConnected;
  IdTCPClient1.OnDisconnected := @HandleClientOnDisconnected;

  //btnConnect.Enabled := False;
  try
    try
      IdTCPClient1.Connect(lbeAddress.Text, StrToIntDef(lbePort.Text, 1883));
      IdTCPClient1.IOHandler.ReadTimeout := 10;
      //AddToLog('Connected to broker...');

      if Th <> nil then
      begin
        Th.Terminate;
        tk := GetTickCount64;
        repeat
          Application.ProcessMessages;
          Sleep(10);
        until (GetTickCount64 - tk > 1500) or Th.Terminated;
        Th := nil;
      end;

      Th := TMQTTReceiveThread.Create(True);
      Th.FreeOnTerminate := False;
      Th.Start;

      if not MQTT_CONNECT(0, 0) then
      begin
        AddToLog('Can''t prepare MQTTConnect packet.');
        Exit;
      end;

      tmrConnect.Enabled := False;
      tmrSubscribe.Enabled := True;
    except
      on E: Exception do
        AddToLog('Can''t connect.  ' + E.Message + '   Class: ' + E.ClassName);
    end;
  finally
    //btnConnect.Enabled := True;
  end;
end;


procedure TfrmFindSubControlWorkerMain.tmrProcessLogTimer(Sender: TObject);
var
  Msg: string;
begin
  if FLoggingFIFO.Pop(Msg) then
    memLog.Lines.Add(DateTimeToStr(Now) + '  ' + (Msg));
end;


procedure TfrmFindSubControlWorkerMain.tmrProcessRecDataTimer(Sender: TObject);
begin
  ProcessReceivedBuffer;
end;


procedure TfrmFindSubControlWorkerMain.tmrStartupTimer(Sender: TObject);
var
  Content: TStringList;
  Fnm: string;
begin
  tmrStartup.Enabled := False;
  tmrProcessLog.Enabled := True;
  tmrProcessRecData.Enabled := True;

  FMQTTPassword := '';

  Content := TStringList.Create;
  try
    Fnm := ExtractFilePath(ParamStr(0)) + 'p.txt';

    if FileExists(Fnm) then
    begin
      Content.LoadFromFile(Fnm);

      if Content.Count > 0 then
        FMQTTPassword := Content.Strings[0]
    end
    else
      AddToLog('Password file not found. Using empty password..');
  finally
    Content.Free;
  end;

  {$IFDEF UsingDynTFT}
    MM_Init;
  {$ENDIF}

  MQTT_Init;
  if not MQTT_CreateClient then
    AddToLog('Can''t create client...');

  InitHandlers;

  tmrConnect.Enabled := True;
end;


procedure TfrmFindSubControlWorkerMain.tmrSubscribeTimer(Sender: TObject);
begin
  if not MQTT_SUBSCRIBE(0, 0) then
  begin
    AddToLog('Can''t prepare MQTT_SUBSCRIBE packet.');
    Exit;
  end;
end;


procedure TfrmFindSubControlWorkerMain.HandleClientOnConnected(Sender: TObject);
begin
  AddToLog('Connected to broker... on port ' + IntToStr(IdTCPClient1.Port));
end;


procedure TfrmFindSubControlWorkerMain.HandleClientOnDisconnected(Sender: TObject);
begin
  AddToLog('Disconnected from broker...');

  try
    if Th <> nil then
      Th.Terminate;

    FreeAndNil(Th);
  except
  end;
end;


end.

